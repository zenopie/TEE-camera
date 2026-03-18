//======================================================================
//
// ed25519_sign.v
// --------------
// Ed25519 signature generation (RFC 8032).
//
// Signing algorithm:
//   1. h = SHA-512(seed)        — 64 bytes
//   2. s = clamp(h[0:31])       — secret scalar
//   3. prefix = h[32:63]        — nonce prefix
//   4. A = [s]B                 — public key point
//   5. r = SHA-512(prefix || msg_hash) mod L  — nonce scalar
//   6. R = [r]B                 — nonce point
//   7. k = SHA-512(R || A || msg_hash) mod L  — challenge
//   8. S = (r + k*s) mod L      — signature scalar
//   9. sig = encode(R) || encode(S)  — 64 bytes
//
// For the camera use case:
//   - Key material (s, prefix, A) from PUF+SHA-512 at boot
//   - msg_hash is the SHA-512 of the camera frame (pre-computed)
//
//======================================================================

`default_nettype none

module ed25519_sign (
    input  wire          clk,
    input  wire          reset_n,

    // Key material (from PUF + SHA-512, computed once at boot)
    input  wire [255:0]  secret_scalar,  // clamped scalar s
    input  wire [255:0]  nonce_prefix,   // SHA-512(seed)[32:63]
    input  wire [254:0]  pub_x, pub_y, pub_z, pub_t,  // public key A = [s]B

    // Message hash (pre-computed SHA-512 of frame data)
    input  wire [511:0]  msg_hash,

    // Control
    input  wire          start,

    // Signature output (64 bytes = 512 bits)
    output reg  [511:0]  signature,
    output reg           done
);

    // Ed25519 base point B
    localparam [254:0] BX = 255'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
    localparam [254:0] BY = 255'h6666666666666666666666666666666666666666666666666666666666666658;
    localparam [254:0] BT = 255'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;

    // Group order L = 2^252 + 27742317777372353535851937790883648493
    localparam [252:0] L = 253'h1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;

    // p = 2^255 - 19
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;

    //----------------------------------------------------------------
    // State machine — 16 states for clear control flow
    //----------------------------------------------------------------
    localparam ST_IDLE         = 4'd0;
    localparam ST_HASH_R       = 4'd1;   // Start SHA-512(prefix || msg_hash)
    localparam ST_HASH_R_RUN   = 4'd2;   // Wait for SHA-512 to start
    localparam ST_HASH_R_DONE  = 4'd3;   // Wait for SHA-512 result
    localparam ST_REDUCE_R     = 4'd4;   // r = hash mod L
    localparam ST_SMUL_R       = 4'd5;   // Start R = [r]B
    localparam ST_SMUL_R_WAIT  = 4'd6;   // Wait for scalar mult
    localparam ST_ENCODE_R     = 4'd7;   // Encode R, start challenge hash block 1
    localparam ST_HASH_K_RUN1  = 4'd8;   // Wait for block 1 to start
    localparam ST_HASH_K_DONE1 = 4'd9;   // Wait for block 1 result
    localparam ST_HASH_K_B2    = 4'd10;  // Send padding block 2
    localparam ST_HASH_K_RUN2  = 4'd11;  // Wait for block 2 to start
    localparam ST_HASH_K_DONE2 = 4'd12;  // Wait for block 2 result
    localparam ST_COMPUTE_S    = 4'd13;  // S = (r + k*s) mod L
    localparam ST_OUTPUT       = 4'd14;
    localparam ST_DONE         = 4'd15;

    reg [3:0] state;

    // Internal storage
    reg [511:0] r_hash;
    reg [254:0] r_scalar;
    reg [254:0] R_enc_y;
    reg         R_enc_sign;
    reg [511:0] k_hash;
    reg [254:0] S_value;
    reg [254:0] R_x, R_y, R_z;
    reg [255:0] R_encoded_reg, A_encoded_reg;

    //----------------------------------------------------------------
    // SHA-512 instance
    //----------------------------------------------------------------
    reg          sha_init, sha_next;
    reg [1023:0] sha_block;
    wire         sha_ready;
    wire [511:0] sha_digest;
    wire         sha_valid;

    sha512_core sha512_inst (
        .clk(clk),
        .reset_n(reset_n),
        .init(sha_init),
        .next(sha_next),
        .mode(2'd3),          // SHA-512 mode
        .work_factor(1'b0),
        .work_factor_num(32'd0),
        .block(sha_block),
        .ready(sha_ready),
        .digest(sha_digest),
        .digest_valid(sha_valid)
    );

    //----------------------------------------------------------------
    // Scalar multiplication instance
    //----------------------------------------------------------------
    reg          smul_start;
    reg  [254:0] smul_scalar;
    wire [254:0] smul_qx, smul_qy, smul_qz, smul_qt;
    wire         smul_done;

    ed25519_scalarmult scalarmult_inst (
        .clk(clk),
        .reset_n(reset_n),
        .scalar(smul_scalar),
        .p_x(BX), .p_y(BY), .p_z(255'd1), .p_t(BT),
        .start(smul_start),
        .q_x(smul_qx), .q_y(smul_qy),
        .q_z(smul_qz), .q_t(smul_qt),
        .done(smul_done)
    );

    //----------------------------------------------------------------
    // Behavioral helpers (simulation only — hardware uses iterative)
    //----------------------------------------------------------------
    function [254:0] reduce_mod_l;
        input [511:0] val;
        reg [511:0] tmp;
        begin
            tmp = val % {{259{1'b0}}, L};
            reduce_mod_l = tmp[254:0];
        end
    endfunction

    function [254:0] fe_mul;
        input [254:0] fa, fb;
        reg [511:0] prod;
        reg [259:0] r1;
        reg [255:0] r2;
        begin
            prod = fa * fb;
            r1 = {5'd0, prod[254:0]} + prod[509:255] * 19;
            r2 = {1'b0, r1[254:0]} + r1[259:255] * 19;
            if (r2 >= {1'b0, P})
                fe_mul = r2[254:0] - P;
            else
                fe_mul = r2[254:0];
        end
    endfunction

    function [254:0] fe_inv;
        input [254:0] z;
        reg [254:0] base, result, exp;
        integer j;
        begin
            exp = P - 2;
            base = z;
            result = 255'd1;
            for (j = 0; j < 255; j = j + 1) begin
                if (exp[j])
                    result = fe_mul(result, base);
                base = fe_mul(base, base);
            end
            fe_inv = result;
        end
    endfunction

    function [255:0] encode_point;
        input [254:0] px, py, pz;
        reg [254:0] zi, ax, ay;
        begin
            zi = fe_inv(pz);
            ax = fe_mul(px, zi);
            ay = fe_mul(py, zi);
            encode_point = {ax[0], ay};  // bit 255 = LSB of x (sign bit)
        end
    endfunction

    //----------------------------------------------------------------
    // Main state machine
    //----------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= ST_IDLE;
            done       <= 0;
            signature  <= 0;
            sha_init   <= 0;
            sha_next   <= 0;
            sha_block  <= 0;
            smul_start <= 0;
            smul_scalar<= 0;
            r_hash     <= 0;
            r_scalar   <= 0;
            k_hash     <= 0;
            S_value    <= 0;
            R_x <= 0; R_y <= 0; R_z <= 0;
            R_enc_y    <= 0;
            R_enc_sign <= 0;
            R_encoded_reg <= 0;
            A_encoded_reg <= 0;
        end else begin
            // Default: deassert one-shot signals
            sha_init   <= 0;
            sha_next   <= 0;
            smul_start <= 0;

            case (state)
                ST_IDLE: begin
                    done <= 0;
                    if (start)
                        state <= ST_HASH_R;
                end

                // ── Nonce hash: r = SHA-512(prefix || msg_hash) ──

                ST_HASH_R: begin
                    // prefix(256) + msg_hash(512) = 768 bits = 96 bytes
                    // Padding: 0x80 + zeros + 128-bit length
                    // Available space: 1024 - 768 - 8 - 128 = 120 bits of zeros
                    sha_block <= {nonce_prefix, msg_hash,
                                  8'h80,
                                  {120{1'b0}},
                                  128'd768};
                    sha_init  <= 1;
                    state     <= ST_HASH_R_RUN;
                end

                ST_HASH_R_RUN: begin
                    // Wait for SHA-512 to start processing (ready drops)
                    if (!sha_ready)
                        state <= ST_HASH_R_DONE;
                end

                ST_HASH_R_DONE: begin
                    if (sha_valid) begin
                        r_hash <= sha_digest;
                        state  <= ST_REDUCE_R;
                    end
                end

                // ── Nonce reduction and scalar mult ──

                ST_REDUCE_R: begin
                    r_scalar <= reduce_mod_l(r_hash);
                    state    <= ST_SMUL_R;
                end

                ST_SMUL_R: begin
                    smul_scalar <= r_scalar;
                    smul_start  <= 1;
                    state       <= ST_SMUL_R_WAIT;
                end

                ST_SMUL_R_WAIT: begin
                    if (smul_done) begin
                        R_x <= smul_qx;
                        R_y <= smul_qy;
                        R_z <= smul_qz;
                        state <= ST_ENCODE_R;
                    end
                end

                // ── Encode R, start challenge hash ──

                ST_ENCODE_R: begin
                    begin
                        reg [255:0] R_enc, A_enc;
                        R_enc = encode_point(R_x, R_y, R_z);
                        A_enc = encode_point(pub_x, pub_y, pub_z);
                        R_enc_y    <= R_enc[254:0];
                        R_enc_sign <= R_enc[255];
                        R_encoded_reg <= R_enc;
                        A_encoded_reg <= A_enc;

                        // Challenge hash block 1: R(256) || A(256) || msg_hash(512) = 1024 bits
                        sha_block <= {R_enc, A_enc, msg_hash};
                        sha_init  <= 1;
                        state     <= ST_HASH_K_RUN1;
                    end
                end

                ST_HASH_K_RUN1: begin
                    // Wait for SHA-512 to start processing
                    if (!sha_ready)
                        state <= ST_HASH_K_DONE1;
                end

                ST_HASH_K_DONE1: begin
                    if (sha_valid)
                        state <= ST_HASH_K_B2;
                end

                ST_HASH_K_B2: begin
                    // Block 2: padding for 1024-bit (128-byte) message
                    // 0x80 + zeros + length(128 bits)
                    // 1024 - 8 - 128 = 888 zero bits
                    sha_block <= {8'h80, {888{1'b0}}, 128'd1024};
                    sha_next  <= 1;
                    state     <= ST_HASH_K_RUN2;
                end

                ST_HASH_K_RUN2: begin
                    if (!sha_ready)
                        state <= ST_HASH_K_DONE2;
                end

                ST_HASH_K_DONE2: begin
                    if (sha_valid) begin
                        k_hash <= sha_digest;
                        state  <= ST_COMPUTE_S;
                    end
                end

                // ── Compute S = (r + k*s) mod L ──

                ST_COMPUTE_S: begin
                    begin
                        reg [254:0] k_reduced;
                        reg [511:0] ks_product;
                        reg [511:0] r_plus_ks;

                        k_reduced  = reduce_mod_l(k_hash);
                        ks_product = k_reduced * secret_scalar[254:0];
                        r_plus_ks  = {257'd0, r_scalar} + ks_product;
                        S_value    <= reduce_mod_l(r_plus_ks);
                        state      <= ST_OUTPUT;
                    end
                end

                // ── Output signature ──

                ST_OUTPUT: begin
                    signature <= {{R_enc_sign, R_enc_y}, {1'b0, S_value}};
                    state     <= ST_DONE;
                end

                ST_DONE: begin
                    done  <= 1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule // ed25519_sign

//======================================================================
// EOF ed25519_sign.v
//======================================================================
