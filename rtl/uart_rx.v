//======================================================================
//
// uart_rx.v
// ---------
// UART receiver. 8N1 format. Samples at mid-bit for reliability.
//
// Parameters:
//   CLK_FREQ  - system clock frequency in Hz (default 24 MHz)
//   BAUD_RATE - baud rate (default 115200)
//
//======================================================================

`default_nettype none

module uart_rx #(
    parameter CLK_FREQ  = 24_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // UART RX pin
    output reg  [7:0] data,      // received byte
    output reg        valid      // pulses high for one cycle when byte ready
);

    // Bit period in clock cycles
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam HALF_BIT     = CLKS_PER_BIT / 2;
    localparam CNT_W = $clog2(CLKS_PER_BIT);

    // State machine
    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_DATA  = 2'd2;
    localparam ST_STOP  = 2'd3;

    reg [1:0]       state;
    reg [CNT_W-1:0] clk_cnt;
    reg [2:0]       bit_idx;
    reg [7:0]       shift_reg;

    // Synchronize RX input (2-stage for metastability)
    reg rx_sync1, rx_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    wire rx_in = rx_sync2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            data      <= 0;
            valid     <= 0;
            clk_cnt   <= 0;
            bit_idx   <= 0;
            shift_reg <= 0;
        end else begin
            valid <= 0;  // default: one-cycle pulse

            case (state)
                ST_IDLE: begin
                    if (rx_in == 1'b0) begin
                        // Falling edge detected — possible start bit
                        clk_cnt <= 0;
                        state   <= ST_START;
                    end
                end

                // Verify start bit at mid-point
                ST_START: begin
                    if (clk_cnt == HALF_BIT) begin
                        if (rx_in == 1'b0) begin
                            // Confirmed start bit
                            clk_cnt <= 0;
                            bit_idx <= 0;
                            state   <= ST_DATA;
                        end else begin
                            // False start — go back to idle
                            state <= ST_IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Sample data bits at mid-point (LSB first)
                ST_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        shift_reg[bit_idx] <= rx_in;
                        if (bit_idx == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // Verify stop bit at mid-point
                ST_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        if (rx_in == 1'b1) begin
                            // Valid stop bit — output byte
                            data  <= shift_reg;
                            valid <= 1;
                        end
                        // Either way, return to idle
                        state   <= ST_IDLE;
                        clk_cnt <= 0;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end
            endcase
        end
    end

endmodule // uart_rx

//======================================================================
// EOF uart_rx.v
//======================================================================
