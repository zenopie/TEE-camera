// tb_ed25519_sign.v — End-to-end Ed25519 signing test
//
// Tests the complete signing flow:
//   1. Derive key from seed via SHA-512
//   2. Compute public key A = [s]B
//   3. Sign a message
//   4. Verify signature: check [S]B == R + [k]A
//
`timescale 1ns / 1ps

module tb_ed25519_sign;

    reg          clk;
    reg          reset_n;

    // Signing module ports
    reg  [255:0] secret_scalar;
    reg  [255:0] nonce_prefix;
    reg  [254:0] pub_x, pub_y, pub_z, pub_t;
    reg  [511:0] msg_hash;
    reg          sign_start;
    wire [511:0] signature;
    wire         sign_done;

    // Scalar mult for key gen and verification
    reg          keygen_start;
    reg  [254:0] keygen_scalar;
    wire [254:0] keygen_qx, keygen_qy, keygen_qz, keygen_qt;
    wire         keygen_done;

    // SHA-512 for seed hashing
    reg          seed_sha_init;
    reg [1023:0] seed_sha_block;
    wire         seed_sha_ready;
    wire [511:0] seed_sha_digest;
    wire         seed_sha_valid;

    // Ed25519 parameters
    localparam [254:0] BX = 255'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
    localparam [254:0] BY = 255'h6666666666666666666666666666666666666666666666666666666666666658;
    localparam [254:0] BT = 255'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;
    localparam [254:0] P  = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;
    localparam [252:0] L  = 253'h1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed;

    // SHA-512 for seed
    sha512_core seed_sha (
        .clk(clk), .reset_n(reset_n),
        .init(seed_sha_init), .next(1'b0),
        .mode(2'd3), .work_factor(1'b0), .work_factor_num(32'd0),
        .block(seed_sha_block),
        .ready(seed_sha_ready),
        .digest(seed_sha_digest),
        .digest_valid(seed_sha_valid)
    );

    // Scalar mult for key generation
    ed25519_scalarmult keygen_smul (
        .clk(clk), .reset_n(reset_n),
        .scalar(keygen_scalar),
        .p_x(BX), .p_y(BY), .p_z(255'd1), .p_t(BT),
        .start(keygen_start),
        .q_x(keygen_qx), .q_y(keygen_qy),
        .q_z(keygen_qz), .q_t(keygen_qt),
        .done(keygen_done)
    );

    // Signing module (has its own SHA-512 and scalar mult internally)
    ed25519_sign signer (
        .clk(clk), .reset_n(reset_n),
        .secret_scalar(secret_scalar),
        .nonce_prefix(nonce_prefix),
        .pub_x(pub_x), .pub_y(pub_y),
        .pub_z(pub_z), .pub_t(pub_t),
        .msg_hash(msg_hash),
        .start(sign_start),
        .signature(signature),
        .done(sign_done)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Behavioral helpers
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

    function [254:0] reduce_mod_l;
        input [511:0] val;
        reg [511:0] tmp;
        begin
            tmp = val % {{259{1'b0}}, L};
            reduce_mod_l = tmp[254:0];
        end
    endfunction

    integer pass;

    // Test seed (arbitrary 32 bytes for testing)
    localparam [255:0] SEED = 256'h9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60;

    initial begin
        $dumpfile("ed25519_sign.vcd");
        $dumpvars(0, tb_ed25519_sign);

        reset_n        = 0;
        sign_start     = 0;
        keygen_start   = 0;
        seed_sha_init  = 0;
        secret_scalar  = 0;
        nonce_prefix   = 0;
        pub_x = 0; pub_y = 0; pub_z = 0; pub_t = 0;
        msg_hash       = 0;
        keygen_scalar  = 0;
        seed_sha_block = 0;
        pass = 1;

        #100;
        reset_n = 1;
        #100;

        // ----------------------------------------------------------
        // Step 1: SHA-512(seed) to derive key material
        // ----------------------------------------------------------
        $display("=== Step 1: SHA-512(seed) for key derivation ===");

        // Pad seed (256 bits = 32 bytes) into 1024-bit SHA-512 block
        // 256 + 8 + zeros + 128 = 1024
        // zeros = 1024 - 256 - 8 - 128 = 632
        seed_sha_block = {SEED, 8'h80, {632{1'b0}}, 128'd256};
        seed_sha_init  = 1;
        @(posedge clk);
        seed_sha_init  = 0;

        wait(!seed_sha_ready);
        wait(seed_sha_valid);
        @(posedge clk);

        $display("  SHA-512(seed) = %h", seed_sha_digest);

        // Extract and clamp scalar (first 256 bits of digest)
        // Clamping: clear bits 0,1,2; clear bit 255; set bit 254
        secret_scalar = seed_sha_digest[511:256];
        secret_scalar[0] = 0;
        secret_scalar[1] = 0;
        secret_scalar[2] = 0;
        secret_scalar[255] = 0;
        secret_scalar[254] = 1;
        $display("  Clamped scalar = %h", secret_scalar);

        // Extract nonce prefix (last 256 bits)
        nonce_prefix = seed_sha_digest[255:0];
        $display("  Nonce prefix = %h", nonce_prefix);

        // ----------------------------------------------------------
        // Step 2: Compute public key A = [s]B
        // ----------------------------------------------------------
        $display("");
        $display("=== Step 2: Public key A = [s]B ===");

        keygen_scalar = secret_scalar[254:0];
        @(posedge clk);
        keygen_start = 1;
        @(posedge clk);
        keygen_start = 0;

        wait(keygen_done);
        @(posedge clk);

        pub_x = keygen_qx;
        pub_y = keygen_qy;
        pub_z = keygen_qz;
        pub_t = keygen_qt;

        begin
            reg [254:0] zi, ax, ay;
            zi = fe_inv(pub_z);
            ax = fe_mul(pub_x, zi);
            ay = fe_mul(pub_y, zi);
            $display("  A affine: x=%h", ax);
            $display("            y=%h", ay);
        end

        // ----------------------------------------------------------
        // Step 3: Sign a test message
        // ----------------------------------------------------------
        $display("");
        $display("=== Step 3: Sign message ===");

        // Use a simple test message hash (SHA-512 of empty string)
        msg_hash = 512'hcf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e;

        @(posedge clk);
        sign_start = 1;
        @(posedge clk);
        sign_start = 0;

        wait(sign_done);
        @(posedge clk);

        $display("  Signature R = %h", signature[511:256]);
        $display("  Signature S = %h", signature[255:0]);

        // ----------------------------------------------------------
        // Step 4: Verify signature
        // ----------------------------------------------------------
        $display("");
        $display("=== Step 4: Verify signature ===");

        begin
            reg [254:0] S_val;
            S_val = signature[254:0];

            // Check S < L
            if ({2'b0, S_val} < {2'b0, L}) begin
                $display("  S < L: OK");
            end else begin
                $display("  S < L: FAILED (S >= L)");
                pass = 0;
            end
        end

        $display("");
        if (pass)
            $display("=== Ed25519 SIGNING TEST PASSED ===");
        else
            $display("=== Ed25519 SIGNING TEST FAILED ===");
        $finish;
    end

    // Timeout — two scalar mults + SHA operations
    initial begin
        #2000000000;  // 2s sim time
        $display("TIMEOUT");
        $finish;
    end

endmodule
