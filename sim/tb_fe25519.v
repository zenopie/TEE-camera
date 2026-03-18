// tb_fe25519.v — Testbench for GF(2^255-19) field arithmetic
`timescale 1ns / 1ps

module tb_fe25519;

    reg         clk;
    reg         reset_n;
    reg  [1:0]  op;
    reg  [254:0] a;
    reg  [254:0] b;
    reg         start;
    wire [254:0] result;
    wire        done;

    fe25519 dut (
        .clk(clk),
        .reset_n(reset_n),
        .op(op),
        .a(a),
        .b(b),
        .start(start),
        .result(result),
        .done(done)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // p = 2^255 - 19
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;

    integer pass;
    integer test_num;

    task run_op;
        input [1:0]   t_op;
        input [254:0] t_a;
        input [254:0] t_b;
        input [254:0] expected;
        begin
            test_num = test_num + 1;
            @(posedge clk);
            op    = t_op;
            a     = t_a;
            b     = t_b;
            start = 1;
            @(posedge clk);
            start = 0;
            wait(done);
            @(posedge clk);

            if (result == expected) begin
                $display("  Test %0d PASSED", test_num);
            end else begin
                $display("  Test %0d FAILED", test_num);
                $display("    a        = %h", t_a);
                $display("    b        = %h", t_b);
                $display("    got      = %h", result);
                $display("    expected = %h", expected);
                pass = 0;
            end
        end
    endtask

    initial begin
        $dumpfile("fe25519.vcd");
        $dumpvars(0, tb_fe25519);

        reset_n  = 0;
        op       = 0;
        a        = 0;
        b        = 0;
        start    = 0;
        pass     = 1;
        test_num = 0;

        #100;
        reset_n = 1;
        #100;

        // ----------------------------------------------------------
        $display("=== FE25519 Addition Tests ===");
        // ----------------------------------------------------------

        // Test 1: 1 + 2 = 3
        run_op(2'd0, 255'd1, 255'd2, 255'd3);

        // Test 2: (p-1) + 1 = 0 (wraps around)
        run_op(2'd0, P - 1, 255'd1, 255'd0);

        // Test 3: (p-1) + (p-1) = p-2 (since 2p-2 mod p = p-2)
        run_op(2'd0, P - 1, P - 1, P - 2);

        // ----------------------------------------------------------
        $display("=== FE25519 Subtraction Tests ===");
        // ----------------------------------------------------------

        // Test 4: 5 - 3 = 2
        run_op(2'd1, 255'd5, 255'd3, 255'd2);

        // Test 5: 0 - 1 = p - 1 (underflow wraps)
        run_op(2'd1, 255'd0, 255'd1, P - 1);

        // Test 6: 3 - 5 = p - 2
        run_op(2'd1, 255'd3, 255'd5, P - 2);

        // ----------------------------------------------------------
        $display("=== FE25519 Multiplication Tests ===");
        // ----------------------------------------------------------

        // Test 7: 2 * 3 = 6
        run_op(2'd2, 255'd2, 255'd3, 255'd6);

        // Test 8: 9 * 9 = 81
        run_op(2'd2, 255'd9, 255'd9, 255'd81);

        // Test 9: (p-1) * 1 = p-1
        run_op(2'd2, P - 1, 255'd1, P - 1);

        // Test 10: (p-1) * 2 = p - 2  (since (p-1)*2 = 2p-2, mod p = p-2)
        run_op(2'd2, P - 1, 255'd2, P - 2);

        // Test 11: 2 * (p-1) = p - 2  (commutativity)
        run_op(2'd2, 255'd2, P - 1, P - 2);

        // Test 12: (p-1) * (p-1) = 1  (since (-1)*(-1) = 1 mod p)
        run_op(2'd2, P - 1, P - 1, 255'd1);

        // ----------------------------------------------------------
        $display("");
        // ----------------------------------------------------------

        #100;
        if (pass)
            $display("=== ALL FE25519 TESTS PASSED ===");
        else
            $display("=== SOME FE25519 TESTS FAILED ===");
        $finish;
    end

    // Timeout
    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
