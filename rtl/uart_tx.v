//======================================================================
//
// uart_tx.v
// ---------
// UART transmitter. 8N1 format (8 data bits, no parity, 1 stop bit).
// Active low TX line (idle = high).
//
// Parameters:
//   CLK_FREQ  - system clock frequency in Hz (default 24 MHz)
//   BAUD_RATE - baud rate (default 115200)
//
//======================================================================

`default_nettype none

module uart_tx #(
    parameter CLK_FREQ  = 24_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,      // byte to send
    input  wire       send,      // pulse to begin transmission
    output reg        tx,        // UART TX pin
    output reg        busy       // high while transmitting
);

    // Bit period in clock cycles
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam CNT_W = $clog2(CLKS_PER_BIT);

    // State machine
    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]       state;
    reg [CNT_W-1:0] clk_cnt;    // clock counter within bit period
    reg [2:0]       bit_idx;    // which data bit (0-7, LSB first)
    reg [7:0]       shift_reg;  // latched data

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            tx        <= 1'b1;   // idle high
            busy      <= 0;
            clk_cnt   <= 0;
            bit_idx   <= 0;
            shift_reg <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tx   <= 1'b1;
                    busy <= 0;
                    if (send) begin
                        shift_reg <= data;
                        busy      <= 1;
                        state     <= ST_START;
                        clk_cnt   <= 0;
                    end
                end

                // Start bit (low)
                ST_START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        state   <= ST_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Data bits (LSB first)
                ST_DATA: begin
                    tx <= shift_reg[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        if (bit_idx == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Stop bit (high)
                ST_STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state   <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule // uart_tx

//======================================================================
// EOF uart_tx.v
//======================================================================
