// tb_boot_keygen.v — Boot key derivation end-to-end test
//
// Tests:
//   1. Full boot flow: PUF → fuzzy extract → SHA-512 → clamp → [s]B
//   2. Scalar is properly clamped (bits 0-2 clear, bit 255 clear, bit 254 set)
//   3. Public key point is on the Ed25519 curve
//
`timescale 1ns / 1ps

module tb_boot_keygen;

    reg          clk;
    reg          rst_n;
    reg          start;

    wire [255:0] secret_scalar;
    wire [255:0] nonce_prefix;
    wire [254:0] pub_x, pub_y, pub_z, pub_t;
    wire         done;

    boot_keygen dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .secret_scalar(secret_scalar),
        .nonce_prefix(nonce_prefix),
        .pub_x(pub_x), .pub_y(pub_y),
        .pub_z(pub_z), .pub_t(pub_t),
        .done(done)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Ed25519 constants
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;
    localparam [254:0] D = 255'h52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3;

    // Behavioral helpers for verification
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

    function [254:0] fe_add;
        input [254:0] fa, fb;
        reg [255:0] sum;
        begin
            sum = {1'b0, fa} + {1'b0, fb};
            if (sum >= {1'b0, P})
                fe_add = sum[254:0] - P;
            else
                fe_add = sum[254:0];
        end
    endfunction

    function [254:0] fe_sub;
        input [254:0] fa, fb;
        begin
            if (fa >= fb)
                fe_sub = fa - fb;
            else
                fe_sub = P - fb + fa;
        end
    endfunction

    integer pass;

    initial begin
        $dumpfile("boot_keygen.vcd");
        $dumpvars(0, tb_boot_keygen);

        rst_n = 0;
        start = 0;
        pass  = 1;

        #100;
        rst_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test: Full boot key derivation
        // ----------------------------------------------------------
        $display("=== Boot Key Derivation Test ===");
        $display("");

        @(posedge clk);
        #1;
        start = 1;
        @(posedge clk);
        #1;
        start = 0;

        $display("  Waiting for key derivation...");

        @(posedge done);
        @(posedge clk);

        $display("  Key derivation complete!");
        $display("");
        $display("  Secret scalar = %h", secret_scalar);
        $display("  Nonce prefix  = %h", nonce_prefix);

        // Check clamping
        $display("");
        $display("--- Clamping checks ---");

        if (secret_scalar[2:0] === 3'b000) begin
            $display("  Bits 0-2 clear: OK");
        end else begin
            $display("  Bits 0-2 clear: FAIL (got %b)", secret_scalar[2:0]);
            pass = 0;
        end

        if (secret_scalar[255] === 1'b0) begin
            $display("  Bit 255 clear:  OK");
        end else begin
            $display("  Bit 255 clear:  FAIL");
            pass = 0;
        end

        if (secret_scalar[254] === 1'b1) begin
            $display("  Bit 254 set:    OK");
        end else begin
            $display("  Bit 254 set:    FAIL");
            pass = 0;
        end

        // Convert public key to affine and check on-curve
        $display("");
        $display("--- Public key on-curve check ---");

        begin
            reg [254:0] zi, ax, ay;
            reg [254:0] x2, y2, dx2y2, lhs, rhs;

            zi = fe_inv(pub_z);
            ax = fe_mul(pub_x, zi);
            ay = fe_mul(pub_y, zi);

            $display("  A.x = %h", ax);
            $display("  A.y = %h", ay);

            // Check: -x^2 + y^2 = 1 + d*x^2*y^2
            x2 = fe_mul(ax, ax);
            y2 = fe_mul(ay, ay);
            dx2y2 = fe_mul(D, fe_mul(x2, y2));
            lhs = fe_sub(y2, x2);               // -x^2 + y^2
            rhs = fe_add(255'd1, dx2y2);         // 1 + d*x^2*y^2

            if (lhs === rhs) begin
                $display("  On curve: OK");
            end else begin
                $display("  On curve: FAIL");
                $display("    LHS = %h", lhs);
                $display("    RHS = %h", rhs);
                pass = 0;
            end
        end

        // Check public key is not identity (0,1,1,0)
        begin
            reg [254:0] zi, ax, ay;
            zi = fe_inv(pub_z);
            ax = fe_mul(pub_x, zi);
            ay = fe_mul(pub_y, zi);
            if (ax == 255'd0 && ay == 255'd1) begin
                $display("  Non-identity: FAIL (public key is identity)");
                pass = 0;
            end else begin
                $display("  Non-identity: OK");
            end
        end

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("");
        if (pass)
            $display("=== BOOT KEYGEN TEST PASSED ===");
        else
            $display("=== BOOT KEYGEN TEST FAILED ===");
        $finish;
    end

    // Timeout — fuzzy extractor + SHA-512 + scalar mult
    initial begin
        #2000000000;  // 2s sim time
        $display("TIMEOUT");
        $finish;
    end

endmodule
