//======================================================================
//
// boot_keygen.v
// -------------
// Boot-time Ed25519 key derivation from PUF.
//
// Flow:
//   1. Fuzzy extractor: PUF measured N times, majority vote → 128 stable bits
//   2. SHA-512(stable_bits): Hash to get 512 bits of key material
//   3. Clamp scalar: s = clamp(hash[255:0])
//   4. Extract nonce prefix: prefix = hash[511:256]
//   5. Compute public key: A = [s]B via scalar multiplication
//
// Outputs are held in registers until next reset/power cycle.
//
//======================================================================

`default_nettype none

module boot_keygen (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,       // pulse to begin key derivation

    // Key material outputs (valid when done=1)
    output reg  [255:0]  secret_scalar,  // clamped scalar s
    output reg  [255:0]  nonce_prefix,   // SHA-512(puf)[32:63]
    output reg  [254:0]  pub_x, pub_y, pub_z, pub_t,  // public key A = [s]B
    output reg           done
);

    // Ed25519 base point B
    localparam [254:0] BX = 255'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
    localparam [254:0] BY = 255'h6666666666666666666666666666666666666666666666666666666666666658;
    localparam [254:0] BT = 255'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;

    //----------------------------------------------------------------
    // State machine
    //----------------------------------------------------------------
    localparam ST_IDLE      = 3'd0;
    localparam ST_FE_START  = 3'd1;  // Trigger fuzzy extractor
    localparam ST_FE_WAIT   = 3'd2;  // Wait for fuzzy extractor, then start SHA
    localparam ST_HASH_WAIT = 3'd3;  // Wait for SHA-512 result
    localparam ST_CLAMP     = 3'd4;  // Clamp scalar, extract prefix
    localparam ST_KEYGEN    = 3'd5;  // Start A = [s]B
    localparam ST_KG_WAIT   = 3'd6;  // Wait for scalar mult
    localparam ST_DONE      = 3'd7;

    reg [2:0] state;

    //----------------------------------------------------------------
    // Fuzzy extractor instance
    //----------------------------------------------------------------
    reg          fe_start;
    wire [127:0] fe_bits;
    wire         fe_done;

    fuzzy_extract #(
        .NUM_BITS(128),
        .NUM_SAMPLES(7)
    ) fe_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(fe_start),
        .stable_bits(fe_bits),
        .done(fe_done)
    );

    //----------------------------------------------------------------
    // SHA-512 instance
    //----------------------------------------------------------------
    reg           sha_init;
    reg  [1023:0] sha_block;
    wire          sha_ready;
    wire [511:0]  sha_digest;
    wire          sha_valid;

    sha512_core sha_inst (
        .clk(clk),
        .reset_n(rst_n),
        .init(sha_init),
        .next(1'b0),
        .mode(2'd3),          // SHA-512 mode
        .work_factor(1'b0),
        .work_factor_num(32'd0),
        .block(sha_block),
        .ready(sha_ready),
        .digest(sha_digest),
        .digest_valid(sha_valid)
    );

    //----------------------------------------------------------------
    // Scalar multiplication instance (for A = [s]B)
    //----------------------------------------------------------------
    reg          smul_start;
    reg  [254:0] smul_scalar;
    wire [254:0] smul_qx, smul_qy, smul_qz, smul_qt;
    wire         smul_done;

    ed25519_scalarmult smul_inst (
        .clk(clk),
        .reset_n(rst_n),
        .scalar(smul_scalar),
        .p_x(BX), .p_y(BY), .p_z(255'd1), .p_t(BT),
        .start(smul_start),
        .q_x(smul_qx), .q_y(smul_qy),
        .q_z(smul_qz), .q_t(smul_qt),
        .done(smul_done)
    );

    //----------------------------------------------------------------
    // Main state machine
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            done           <= 0;
            fe_start       <= 0;
            sha_init       <= 0;
            sha_block      <= 0;
            smul_start     <= 0;
            smul_scalar    <= 0;
            secret_scalar  <= 0;
            nonce_prefix   <= 0;
            pub_x <= 0; pub_y <= 0; pub_z <= 0; pub_t <= 0;
        end else begin
            // Default: deassert one-shot signals
            fe_start   <= 0;
            sha_init   <= 0;
            smul_start <= 0;

            case (state)
                ST_IDLE: begin
                    done <= 0;
                    if (start)
                        state <= ST_FE_START;
                end

                // ── Step 1: Fuzzy extractor ──
                ST_FE_START: begin
                    fe_start <= 1;
                    state    <= ST_FE_WAIT;
                end

                ST_FE_WAIT: begin
                    if (fe_done) begin
                        // Pad 128-bit PUF output for SHA-512
                        // 128 bits + 0x80 + zeros + 128-bit length
                        // zeros = 1024 - 128 - 8 - 128 = 760
                        sha_block <= {fe_bits, 8'h80, {760{1'b0}}, 128'd128};
                        sha_init  <= 1;
                        state     <= ST_HASH_WAIT;
                    end
                end

                // ── Step 2: Wait for SHA-512 ──
                ST_HASH_WAIT: begin
                    if (!sha_ready)
                        ; // SHA-512 is processing, wait
                    else if (sha_valid)
                        state <= ST_CLAMP;
                end

                // ── Step 3: Clamp scalar, extract prefix ──
                ST_CLAMP: begin
                    // Clamping (RFC 8032): clear bits 0,1,2; clear bit 255; set bit 254
                    // Single assignment to avoid multi-drive issues
                    secret_scalar <= {1'b0, 1'b1, sha_digest[509:259], 3'b000};
                    nonce_prefix  <= sha_digest[255:0];
                    state         <= ST_KEYGEN;
                end

                // ── Step 4: Start public key computation A = [s]B ──
                ST_KEYGEN: begin
                    smul_scalar <= secret_scalar[254:0];
                    smul_start  <= 1;
                    state       <= ST_KG_WAIT;
                end

                // ── Step 5: Wait for scalar mult ──
                ST_KG_WAIT: begin
                    if (smul_done) begin
                        pub_x <= smul_qx;
                        pub_y <= smul_qy;
                        pub_z <= smul_qz;
                        pub_t <= smul_qt;
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    done  <= 1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule // boot_keygen

//======================================================================
// EOF boot_keygen.v
//======================================================================
