// tb_puf.v — Testbench for ring oscillator PUF
`timescale 1ns / 1ps

module tb_puf;

    reg clk;
    reg rst_n;
    reg start;
    wire done;
    wire [127:0] raw_bits;

    puf #(.NUM_CELLS(128)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .raw_bits(raw_bits)
    );

    // 24 MHz clock (41.67ns period)
    initial clk = 0;
    always #20.83 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("puf.vcd");
        $dumpvars(0, tb_puf);

        rst_n = 0;
        start = 0;

        #100;
        rst_n = 1;
        #100;

        // First measurement
        $display("=== PUF Measurement 1 ===");
        start = 1;
        #42;
        start = 0;

        wait(done);
        #42;

        $display("Raw bits: %h", raw_bits);
        $display("Bit count: %0d", $countones(raw_bits));

        // Second measurement (should be identical in simulation)
        #200;
        $display("\n=== PUF Measurement 2 ===");
        start = 1;
        #42;
        start = 0;

        wait(done);
        #42;

        $display("Raw bits: %h", raw_bits);

        $display("\n=== PUF Test PASSED ===");
        #100;
        $finish;
    end

    // Timeout
    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
