// tb_soc.v — Testbench for RISC-V SoC camera attestation
//
// Boots CPU, waits for PK packet, sends frames, waits for signatures.
// CPU runs Ed25519 in C — much slower than hardware, needs longer timeout.

`timescale 1ns / 1ps

module tb_soc;

    localparam CLK_FREQ   = 24_000_000;
    localparam BAUD_RATE  = 921_600;  // fast baud for sim

    reg        clk;
    reg        rst_n;
    reg        vsync;
    reg        href;
    reg  [7:0] pixel_data;
    wire       uart_txd;
    wire       boot_done;
    wire       signing;

    soc_top #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .BATCH_SIZE(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .vsync(vsync),
        .href(href),
        .pixel_data(pixel_data),
        .uart_txd(uart_txd),
        .uart_rxd(1'b1),
        .boot_done(boot_done),
        .signing(signing)
    );

    // UART RX monitor
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) rx_monitor (
        .clk(clk), .rst_n(rst_n),
        .rx(uart_txd), .data(rx_data), .valid(rx_valid)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Byte counter
    integer uart_file;
    integer byte_count;

    always @(posedge clk) begin
        if (rx_valid) begin
            $fwrite(uart_file, "%c", rx_data);
            byte_count = byte_count + 1;
            if (byte_count <= 34 || (byte_count % 50 == 0))
                $display("  [%0t] UART byte %0d: 0x%02h", $time, byte_count, rx_data);
        end
    end

    // Send one DVP frame
    task send_frame;
        input integer seed;
        integer row, col;
        reg [31:0] rng;
        begin
            rng = seed;
            @(posedge clk); #1;
            vsync = 1;
            repeat(10) @(posedge clk); #1;
            vsync = 0;
            repeat(5) @(posedge clk);

            for (row = 0; row < 8; row = row + 1) begin
                @(posedge clk); #1;
                href = 1;
                for (col = 0; col < 32; col = col + 1) begin
                    rng = rng ^ (rng << 13);
                    rng = rng ^ (rng >> 17);
                    rng = rng ^ (rng << 5);
                    pixel_data = rng[7:0];
                    @(posedge clk); #1;
                end
                href = 0;
                pixel_data = 0;
                repeat(8) @(posedge clk);
            end

            repeat(20) @(posedge clk); #1;
            vsync = 1;
            repeat(10) @(posedge clk); #1;
            vsync = 0;
        end
    endtask

    initial begin
        uart_file  = $fopen("output/uart_output.bin", "wb");
        byte_count = 0;
        rst_n      = 0;
        vsync      = 0;
        href       = 0;
        pixel_data = 0;

        #200;
        rst_n = 1;
        #100;

        // Wait for PUF done (CPU starts deriving keys)
        $display("=== Waiting for PUF... ===");
        wait(boot_done);
        $display("  PUF done at %0t", $time);

        // Wait for public key packet (CPU computes [s]B then sends 34 bytes)
        // Ed25519 scalar mult in software takes millions of cycles
        $display("=== Waiting for public key (CPU computing Ed25519)... ===");
        wait(byte_count >= 34);
        $display("  Public key sent (%0d bytes at %0t)", byte_count, $time);

        // Send a frame
        $display("");
        $display("=== Sending frame 1 ===");
        send_frame(42);
        $display("  Frame sent, waiting for signature...");

        // Wait for signature packet (6 + 64 + 64 = 134 bytes)
        wait(byte_count >= 168);
        $display("  Signature complete (%0d bytes at %0t)", byte_count, $time);

        $fclose(uart_file);
        $display("");
        $display("=== SUCCESS: %0d UART bytes written ===", byte_count);
        $finish;
    end

    // Timeout — Ed25519 in software is slow, give it 60 seconds sim time
    initial begin
        #60_000_000_000;  // 60 seconds
        $display("TIMEOUT at %0t", $time);
        $display("  byte_count=%0d, boot_done=%0b, signing=%0b", byte_count, boot_done, signing);
        $fclose(uart_file);
        $finish;
    end

endmodule
