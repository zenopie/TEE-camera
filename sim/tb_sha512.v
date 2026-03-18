// tb_sha512.v — Testbench for secworks SHA-512 core
// Tests against known vector: SHA-512("abc")
`timescale 1ns / 1ps

module tb_sha512;

    reg          clk;
    reg          reset_n;
    reg          init;
    reg          next;
    reg [1:0]    mode;
    reg          work_factor;
    reg [31:0]   work_factor_num;
    reg [1023:0] block;
    wire         ready;
    wire [511:0] digest;
    wire         digest_valid;

    sha512_core dut (
        .clk(clk),
        .reset_n(reset_n),
        .init(init),
        .next(next),
        .mode(mode),
        .work_factor(work_factor),
        .work_factor_num(work_factor_num),
        .block(block),
        .ready(ready),
        .digest(digest),
        .digest_valid(digest_valid)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Expected: SHA-512("abc") =
    // ddaf35a193617aba cc417349ae204131 12e6fa4e89a97ea2 0a9eeee64b55d39a
    // 2192992a274fc1a8 36ba3c23a3feebbd 454d4423643ce80e 2a9ac94fa54ca49f
    localparam [511:0] EXPECTED = 512'hddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f;

    integer pass;

    initial begin
        $dumpfile("sha512.vcd");
        $dumpvars(0, tb_sha512);

        reset_n         = 0;
        init            = 0;
        next            = 0;
        mode            = 2'd3;  // SHA-512 mode
        work_factor     = 0;
        work_factor_num = 0;
        block           = 0;
        pass            = 1;

        #100;
        reset_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test 1: SHA-512("abc")
        // ----------------------------------------------------------
        $display("=== SHA-512 Test 1: hash of 'abc' ===");

        // Pre-padded 1024-bit block for "abc" (3 bytes = 24 bits)
        // "abc" = 0x616263, then 0x80, then zeros, then length = 24 = 0x18
        block = {64'h6162638000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000018};

        // Start hash (init = first block)
        @(posedge clk);
        init = 1;
        @(posedge clk);
        init = 0;

        // Wait for completion
        wait(digest_valid);
        @(posedge clk);

        $display("Got:      %h", digest);
        $display("Expected: %h", EXPECTED);

        if (digest == EXPECTED) begin
            $display("=== SHA-512 Test 1 PASSED ===");
        end else begin
            $display("=== SHA-512 Test 1 FAILED ===");
            pass = 0;
        end

        // ----------------------------------------------------------
        // Test 2: SHA-512("") — empty message
        // ----------------------------------------------------------
        $display("");
        $display("=== SHA-512 Test 2: hash of '' (empty) ===");

        // Pre-padded block for empty message: 0x80, then zeros, length = 0
        block = {64'h8000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000,
                 64'h0000000000000000};

        // Wait for core to be ready, then start
        wait(ready);
        @(posedge clk);
        init = 1;
        @(posedge clk);
        init = 0;

        // Wait for processing to start (ready goes low)
        wait(!ready);
        // Then wait for completion
        wait(digest_valid);
        @(posedge clk);

        // SHA-512("") = cf83e1357eefb8bd...
        if (digest == 512'hcf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e) begin
            $display("=== SHA-512 Test 2 PASSED ===");
        end else begin
            $display("Got:      %h", digest);
            $display("=== SHA-512 Test 2 FAILED ===");
            pass = 0;
        end

        #100;
        if (pass)
            $display("\n=== ALL SHA-512 TESTS PASSED ===");
        else
            $display("\n=== SOME SHA-512 TESTS FAILED ===");
        $finish;
    end

    // Timeout
    initial begin
        #5000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
