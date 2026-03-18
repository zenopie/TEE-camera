// tb_uart.v — UART TX/RX loopback test
//
// Wires TX output directly to RX input.
// Tests:
//   1. Send single byte, verify received correctly
//   2. Send multiple bytes back-to-back
//   3. Send 0x00 and 0xFF edge cases
//
`timescale 1ns / 1ps

module tb_uart;

    // Use faster baud for simulation (less cycles to wait)
    localparam CLK_FREQ  = 24_000_000;
    localparam BAUD_RATE = 921_600;
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // ~26

    reg        clk;
    reg        rst_n;

    // TX side
    reg  [7:0] tx_data;
    reg        tx_send;
    wire       tx_pin;
    wire       tx_busy;

    // RX side
    wire [7:0] rx_data;
    wire       rx_valid;

    // Loopback: TX → RX
    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) utx (
        .clk(clk), .rst_n(rst_n),
        .data(tx_data), .send(tx_send),
        .tx(tx_pin), .busy(tx_busy)
    );

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) urx (
        .clk(clk), .rst_n(rst_n),
        .rx(tx_pin),
        .data(rx_data), .valid(rx_valid)
    );

    // 24 MHz clock
    initial clk = 0;
    always #20.83 clk = ~clk;

    // Task: send one byte and wait for TX to finish
    task send_byte;
        input [7:0] b;
        begin
            @(posedge clk); #1;
            tx_data = b;
            tx_send = 1;
            @(posedge clk); #1;
            tx_send = 0;
            // Wait for TX to finish
            wait(!tx_busy);
            @(posedge clk);
        end
    endtask

    // Task: wait for RX valid and check value
    task expect_byte;
        input [7:0] expected;
        begin
            @(posedge rx_valid);
            @(posedge clk);
            if (rx_data === expected)
                $display("  OK: received 0x%02h", rx_data);
            else begin
                $display("  FAIL: expected 0x%02h, got 0x%02h", expected, rx_data);
                pass = 0;
            end
        end
    endtask

    integer pass;

    initial begin
        $dumpfile("uart.vcd");
        $dumpvars(0, tb_uart);

        rst_n   = 0;
        tx_data = 0;
        tx_send = 0;
        pass    = 1;

        #100;
        rst_n = 1;
        #100;

        // ----------------------------------------------------------
        // Test 1: Single byte
        // ----------------------------------------------------------
        $display("=== Test 1: Single byte (0x55) ===");
        fork
            send_byte(8'h55);
            expect_byte(8'h55);
        join

        #500;

        // ----------------------------------------------------------
        // Test 2: Multiple bytes back-to-back
        // ----------------------------------------------------------
        $display("");
        $display("=== Test 2: Multiple bytes (A, B, C) ===");
        fork
            begin
                send_byte(8'h41);  // 'A'
                send_byte(8'h42);  // 'B'
                send_byte(8'h43);  // 'C'
            end
            begin
                expect_byte(8'h41);
                expect_byte(8'h42);
                expect_byte(8'h43);
            end
        join

        #500;

        // ----------------------------------------------------------
        // Test 3: Edge cases (0x00 and 0xFF)
        // ----------------------------------------------------------
        $display("");
        $display("=== Test 3: Edge cases (0x00, 0xFF) ===");
        fork
            begin
                send_byte(8'h00);
                send_byte(8'hFF);
            end
            begin
                expect_byte(8'h00);
                expect_byte(8'hFF);
            end
        join

        // ----------------------------------------------------------
        // Summary
        // ----------------------------------------------------------
        $display("");
        if (pass)
            $display("=== UART TEST PASSED ===");
        else
            $display("=== UART TEST FAILED ===");
        $finish;
    end

    // Timeout
    initial begin
        #50000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
