// tb_fuzzy_extract.v — Testbench for fuzzy extractor
//
// Tests:
//   1. Basic operation: fuzzy extractor produces stable 128-bit output
//   2. Consistency: running twice produces the same output (deterministic PUF)
//
`timescale 1ns / 1ps

module tb_fuzzy_extract;

    reg          clk;
    reg          rst_n;
    reg          start;
    wire [127:0] stable_bits;
    wire         done;

    fuzzy_extract #(
        .NUM_BITS(128),
        .NUM_SAMPLES(7)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .stable_bits(stable_bits),
        .done(done)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Task to pulse start with clean timing
    task pulse_start;
        begin
            @(posedge clk);
            #1;
            start = 1;
            @(posedge clk);
            #1;
            start = 0;
        end
    endtask

    reg [127:0] first_result;
    integer pass;

    initial begin
        $dumpfile("fuzzy_extract.vcd");
        $dumpvars(0, tb_fuzzy_extract);

        rst_n = 0;
        start = 0;
        pass  = 1;

        #100;
        rst_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test 1: Basic extraction
        // ----------------------------------------------------------
        $display("=== Test 1: Basic fuzzy extraction ===");

        pulse_start;

        @(posedge done);
        @(posedge clk);

        first_result = stable_bits;
        $display("  Stable bits = %h", stable_bits);

        if (stable_bits === 128'h0 || stable_bits === {128{1'b1}}) begin
            $display("  FAIL: output is all zeros or all ones");
            pass = 0;
        end else begin
            $display("  OK: non-trivial output");
        end

        #200;

        // ----------------------------------------------------------
        // Test 2: Consistency — same PUF should give same result
        // ----------------------------------------------------------
        $display("");
        $display("=== Test 2: Consistency (run again) ===");

        pulse_start;

        @(posedge done);
        @(posedge clk);

        $display("  Stable bits = %h", stable_bits);

        if (stable_bits === first_result) begin
            $display("  OK: consistent output across runs");
        end else begin
            $display("  FAIL: output changed between runs");
            pass = 0;
        end

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("");
        if (pass)
            $display("=== FUZZY EXTRACT TEST PASSED ===");
        else
            $display("=== FUZZY EXTRACT TEST FAILED ===");
        $finish;
    end

    // Timeout
    initial begin
        #100000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
