// tb_ed25519_point.v — Testbench for Ed25519 point operations + scalar mult
//
// Test: Compute public key A = [s]B for RFC 8032 Test Vector 1
//   Private key seed: 9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
//   SHA-512(seed)[0:31] clamped → scalar s
//   Expected public key (y-coord, compressed): d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3
//
// The public key in Ed25519 is the y-coordinate of [s]B with the sign of x in bit 255.
//
`timescale 1ns / 1ps

module tb_ed25519_point;

    reg         clk;
    reg         reset_n;
    reg [254:0] scalar;
    reg [254:0] p_x, p_y, p_z, p_t;
    reg         start;
    wire [254:0] q_x, q_y, q_z, q_t;
    wire        done;

    ed25519_scalarmult dut (
        .clk(clk),
        .reset_n(reset_n),
        .scalar(scalar),
        .p_x(p_x), .p_y(p_y), .p_z(p_z), .p_t(p_t),
        .start(start),
        .q_x(q_x), .q_y(q_y), .q_z(q_z), .q_t(q_t),
        .done(done)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Ed25519 base point B
    // Bx = 15112221349535400772501151409588531511454012693041857206046113283949847762202
    // By = 46316835694926478169428394003475163141307993866256225615783033603165251855960
    localparam [254:0] BX = 255'h216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51a;
    localparam [254:0] BY = 255'h6666666666666666666666666666666666666666666666666666666666666658;

    // B has Z=1, T = Bx*By mod p
    // For simulation, we compute T = Bx * By mod p at load time by just
    // providing the known value. T(B) is a known constant.
    // Bx * By mod p = 0x67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3
    localparam [254:0] BT = 255'h67875f0fd78b766566ea4e8e64abe37d20f09f80775152f56dde8ab3a5b7dda3;

    // p = 2^255 - 19
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;

    // RFC 8032 Test Vector 1:
    // Private key (seed): 9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
    // SHA-512(seed) first 32 bytes (little-endian), then clamped:
    //   Raw: 305995b16827b06ab0fa7b24d80fdc915da3327e4759b41b9e41c13c6b21d30c...
    //   After clamping (clear bits 0,1,2,255; set bit 254):
    //   scalar s = ...
    //
    // For this test, we'll use a small known scalar to verify point ops
    // work correctly, then graduate to the full RFC vector.
    //
    // Test 1: [1]B should equal B itself
    // Test 2: [2]B via scalar mult should give a valid point

    integer pass;

    // For converting projective → affine, we need modular inverse.
    // In simulation, we'll check projective identity: Q.Y * P.Z == P.Y * Q.Z
    // (i.e., the y-coordinates match in projective form)

    // Helper: compute a*b mod p using 512-bit intermediate
    // (behavioral, simulation only)
    function [254:0] fe_mul;
        input [254:0] fa, fb;
        reg [511:0] prod;
        reg [259:0] r1;
        reg [255:0] r2;
        begin
            prod = fa * fb;
            // Reduce: split at bit 255, multiply high by 19
            r1 = {5'd0, prod[254:0]} + prod[509:255] * 19;
            // Second pass
            r2 = {1'b0, r1[254:0]} + r1[259:255] * 19;
            // Final reduction
            if (r2 >= {1'b0, P})
                fe_mul = r2[254:0] - P;
            else
                fe_mul = r2[254:0];
        end
    endfunction

    reg [254:0] affine_x, affine_y;
    reg [254:0] z_inv;

    // Modular exponentiation for inverse (z^(p-2) mod p) — simulation only
    // Using simple square-and-multiply
    task compute_z_inv;
        input [254:0] z;
        output [254:0] inv;
        reg [254:0] base, result, exp;
        integer j;
        begin
            // inv = z^(p-2) mod p
            exp = P - 2;
            base = z;
            result = 255'd1;
            for (j = 0; j < 255; j = j + 1) begin
                if (exp[j])
                    result = fe_mul(result, base);
                base = fe_mul(base, base);
            end
            inv = result;
        end
    endtask

    initial begin
        $dumpfile("ed25519_point.vcd");
        $dumpvars(0, tb_ed25519_point);

        reset_n = 0;
        start   = 0;
        scalar  = 0;
        p_x = 0; p_y = 0; p_z = 0; p_t = 0;
        pass = 1;

        #100;
        reset_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test 1: [1]B = B
        // ----------------------------------------------------------
        $display("=== Ed25519 Test 1: [1]B == B ===");
        scalar = 255'd1;
        p_x = BX;
        p_y = BY;
        p_z = 255'd1;
        p_t = BT;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait(done);
        @(posedge clk);

        // Convert result to affine: x = X/Z, y = Y/Z
        $display("  Q projective: X=%h", q_x);
        $display("                Y=%h", q_y);
        $display("                Z=%h", q_z);
        $display("                T=%h", q_t);

        compute_z_inv(q_z, z_inv);
        affine_x = fe_mul(q_x, z_inv);
        affine_y = fe_mul(q_y, z_inv);

        $display("  Q affine: x=%h", affine_x);
        $display("            y=%h", affine_y);
        $display("  Expected: x=%h", BX);
        $display("            y=%h", BY);

        if (affine_x == BX && affine_y == BY) begin
            $display("  === Test 1 PASSED ===");
        end else begin
            $display("  === Test 1 FAILED ===");
            pass = 0;
        end

        // ----------------------------------------------------------
        // Test 2: [2]B — verify it's on the curve
        // ----------------------------------------------------------
        #200;
        $display("");
        $display("=== Ed25519 Test 2: [2]B on curve ===");
        scalar = 255'd2;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait(done);
        @(posedge clk);

        compute_z_inv(q_z, z_inv);
        affine_x = fe_mul(q_x, z_inv);
        affine_y = fe_mul(q_y, z_inv);

        $display("  [2]B affine: x=%h", affine_x);
        $display("               y=%h", affine_y);

        // Verify curve equation: -x^2 + y^2 == 1 + d*x^2*y^2 (mod p)
        begin
            reg [254:0] x2, y2, lhs, rhs, dval, xy2, dxy2;
            // d = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3
            dval = 255'h52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3;
            x2 = fe_mul(affine_x, affine_x);
            y2 = fe_mul(affine_y, affine_y);
            // lhs = -x^2 + y^2 = y^2 - x^2 mod p
            if (y2 >= x2)
                lhs = y2 - x2;
            else
                lhs = P - x2 + y2;
            // rhs = 1 + d*x^2*y^2
            xy2 = fe_mul(x2, y2);
            dxy2 = fe_mul(dval, xy2);
            rhs = dxy2 + 1;
            if (rhs >= P) rhs = rhs - P;

            $display("  Curve check: LHS=%h", lhs);
            $display("               RHS=%h", rhs);

            if (lhs == rhs) begin
                $display("  === Test 2 PASSED (on curve) ===");
            end else begin
                $display("  === Test 2 FAILED (not on curve) ===");
                pass = 0;
            end
        end

        #100;
        if (pass)
            $display("\n=== ALL Ed25519 POINT TESTS PASSED ===");
        else
            $display("\n=== SOME Ed25519 POINT TESTS FAILED ===");
        $finish;
    end

    // Timeout — scalar mult takes many cycles
    initial begin
        #500000000;  // 500ms sim time
        $display("TIMEOUT");
        $finish;
    end

endmodule
