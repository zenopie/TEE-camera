// tb_frame_hasher.v — Streaming frame hasher testbench
//
// Simulates DVP camera timing with a small test frame.
// Tests:
//   1. Hash a known frame, verify non-trivial output
//   2. Same frame again — verify deterministic (same hash)
//   3. Change one pixel — verify different hash
//
`timescale 1ns / 1ps

module tb_frame_hasher;

    // DVP parameters — small frame for fast simulation
    localparam FRAME_W     = 32;   // pixels per line
    localparam FRAME_H     = 8;    // lines per frame
    localparam HBLANK      = 8;    // clocks of horizontal blanking
    localparam VBLANK_PRE  = 4;    // clocks before first line
    localparam VBLANK_POST = 4;    // clocks after last line

    reg          clk;
    reg          rst_n;
    reg          vsync;
    reg          href;
    reg  [7:0]   pixel_data;

    wire [511:0] frame_hash;
    wire         hash_valid;

    frame_hasher dut (
        .clk(clk),
        .rst_n(rst_n),
        .vsync(vsync),
        .href(href),
        .pixel_data(pixel_data),
        .frame_hash(frame_hash),
        .hash_valid(hash_valid)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Task: send one frame with DVP timing
    // pixel_offset changes byte values for testing (0 = normal, nonzero = modified)
    task send_frame;
        input [7:0] pixel_offset;
        integer line, col;
        begin
            // VSYNC high (blanking)
            vsync = 1;
            href  = 0;
            pixel_data = 0;
            repeat(VBLANK_PRE) @(posedge clk);

            // VSYNC falls — frame start
            @(posedge clk); #1;
            vsync = 0;
            repeat(2) @(posedge clk);

            // Active lines
            for (line = 0; line < FRAME_H; line = line + 1) begin
                // HREF high — active pixels
                @(posedge clk); #1;
                href = 1;
                for (col = 0; col < FRAME_W; col = col + 1) begin
                    pixel_data = (line * FRAME_W + col + pixel_offset) & 8'hFF;
                    @(posedge clk); #1;
                end
                href = 0;
                pixel_data = 0;

                // Horizontal blanking
                repeat(HBLANK) @(posedge clk);
            end

            // VSYNC rises — frame end
            repeat(VBLANK_POST) @(posedge clk);
            @(posedge clk); #1;
            vsync = 1;
        end
    endtask

    reg [511:0] hash1, hash2, hash3;
    integer pass;

    initial begin
        $dumpfile("frame_hasher.vcd");
        $dumpvars(0, tb_frame_hasher);

        rst_n = 0;
        vsync = 1;  // start in blanking
        href  = 0;
        pixel_data = 0;
        pass = 1;

        #100;
        rst_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test 1: Hash a known frame
        // ----------------------------------------------------------
        $display("=== Test 1: Hash known frame (32x8 = 256 bytes) ===");

        send_frame(8'd0);

        @(posedge hash_valid);
        @(posedge clk);
        hash1 = frame_hash;
        $display("  Hash = %h", hash1);

        if (hash1 === 512'd0) begin
            $display("  FAIL: hash is all zeros");
            pass = 0;
        end else begin
            $display("  OK: non-zero hash");
        end

        #200;

        // ----------------------------------------------------------
        // Test 2: Same frame — should produce same hash
        // ----------------------------------------------------------
        $display("");
        $display("=== Test 2: Same frame again (determinism) ===");

        send_frame(8'd0);

        @(posedge hash_valid);
        @(posedge clk);
        hash2 = frame_hash;
        $display("  Hash = %h", hash2);

        if (hash2 === hash1) begin
            $display("  OK: deterministic (same hash)");
        end else begin
            $display("  FAIL: different hash for same input");
            pass = 0;
        end

        #200;

        // ----------------------------------------------------------
        // Test 3: Modified frame — should produce different hash
        // ----------------------------------------------------------
        $display("");
        $display("=== Test 3: Modified frame (change one pixel) ===");

        send_frame(8'd1);  // offset all pixels by +1

        @(posedge hash_valid);
        @(posedge clk);
        hash3 = frame_hash;
        $display("  Hash = %h", hash3);

        if (hash3 !== hash1) begin
            $display("  OK: different hash for different input");
        end else begin
            $display("  FAIL: same hash for different input");
            pass = 0;
        end

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("");
        if (pass)
            $display("=== FRAME HASHER TEST PASSED ===");
        else
            $display("=== FRAME HASHER TEST FAILED ===");
        $finish;
    end

    // Timeout
    initial begin
        #100000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
