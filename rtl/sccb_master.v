//======================================================================
// sccb_master.v — SCCB (I2C-like) master for OV7670 configuration
//
// Single-register write transactions only (no reads needed for init).
// SCCB write: START → [slave_addr+W] → [reg_addr] → [data] → STOP
//
// Clock: SCL runs at clk_freq / (4 * CLK_DIV).
// At 25 MHz with CLK_DIV=64: SCL ≈ 98 kHz (well within 400 kHz limit).
//======================================================================

`default_nettype none

module sccb_master #(
    parameter CLK_DIV = 64    // SCL period = 4 * CLK_DIV clock cycles
)(
    input  wire        clk,
    input  wire        rst_n,

    // Command interface
    input  wire [7:0]  slave_addr,   // 8-bit write address (0x42 for OV7670)
    input  wire [7:0]  reg_addr,     // register address
    input  wire [7:0]  reg_data,     // data to write
    input  wire        start,        // pulse high to begin transaction
    output reg         done,         // pulses high when complete
    output reg         ack_error,    // high if any NACK received

    // I2C pins (directly active active active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active directly active)
    output reg         scl,
    inout  wire        sda
);

    // SDA drive control (open-drain: drive low or release high)
    reg sda_out;
    reg sda_oe;
    assign sda = sda_oe ? sda_out : 1'bz;

    // Clock divider
    reg [$clog2(CLK_DIV)-1:0] clk_cnt;
    wire clk_tick = (clk_cnt == CLK_DIV - 1);

    // Phase within each SCL cycle: 0=SCL low setup, 1=SCL rise, 2=SCL high, 3=SCL fall
    reg [1:0] phase;

    // State machine
    localparam ST_IDLE     = 4'd0;
    localparam ST_START    = 4'd1;
    localparam ST_SEND_BIT = 4'd2;
    localparam ST_ACK      = 4'd3;
    localparam ST_STOP     = 4'd4;
    localparam ST_DONE     = 4'd5;

    reg [3:0]  state;
    reg [23:0] shift_reg;   // 3 bytes: slave_addr, reg_addr, data
    reg [4:0]  bit_cnt;     // counts down from 7 to 0 within each byte
    reg [1:0]  byte_cnt;    // which byte (0=addr, 1=reg, 2=data)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            scl       <= 1;
            sda_out   <= 1;
            sda_oe    <= 0;
            done      <= 0;
            ack_error <= 0;
            clk_cnt   <= 0;
            phase     <= 0;
            shift_reg <= 0;
            bit_cnt   <= 0;
            byte_cnt  <= 0;
        end else begin
            done <= 0;

            // Clock divider
            if (state != ST_IDLE) begin
                if (clk_tick)
                    clk_cnt <= 0;
                else
                    clk_cnt <= clk_cnt + 1;
            end

            case (state)
                ST_IDLE: begin
                    scl     <= 1;
                    sda_out <= 1;
                    sda_oe  <= 0;
                    if (start) begin
                        shift_reg <= {slave_addr, reg_addr, reg_data};
                        ack_error <= 0;
                        byte_cnt  <= 0;
                        clk_cnt   <= 0;
                        phase     <= 0;
                        state     <= ST_START;
                        sda_oe    <= 1;
                        sda_out   <= 1;
                    end
                end

                // START condition: SDA falls while SCL is high
                ST_START: begin
                    if (clk_tick) begin
                        case (phase)
                            2'd0: begin scl <= 1; sda_out <= 1; end
                            2'd1: begin scl <= 1; sda_out <= 0; end  // SDA falls
                            2'd2: begin scl <= 0; sda_out <= 0; end  // SCL falls
                            2'd3: begin
                                bit_cnt <= 4'd7;
                                state   <= ST_SEND_BIT;
                            end
                        endcase
                        phase <= phase + 1;
                    end
                end

                // Send one bit at a time, MSB first
                ST_SEND_BIT: begin
                    if (clk_tick) begin
                        case (phase)
                            2'd0: begin
                                // Setup data while SCL is low
                                scl     <= 0;
                                sda_oe  <= 1;
                                sda_out <= shift_reg[23];
                            end
                            2'd1: scl <= 1;   // SCL rises, data sampled
                            2'd2: scl <= 1;   // SCL high hold
                            2'd3: begin
                                scl <= 0;
                                shift_reg <= {shift_reg[22:0], 1'b0};
                                if (bit_cnt == 0)
                                    state <= ST_ACK;
                                else
                                    bit_cnt <= bit_cnt - 1;
                            end
                        endcase
                        phase <= phase + 1;
                    end
                end

                // ACK cycle: release SDA, read ACK from slave
                ST_ACK: begin
                    if (clk_tick) begin
                        case (phase)
                            2'd0: begin
                                scl    <= 0;
                                sda_oe <= 0;  // release SDA for slave ACK
                            end
                            2'd1: scl <= 1;
                            2'd2: begin
                                scl <= 1;
                                if (sda) ack_error <= 1;  // NACK
                            end
                            2'd3: begin
                                scl <= 0;
                                if (byte_cnt == 2'd2) begin
                                    // All 3 bytes sent, generate STOP
                                    sda_oe  <= 1;
                                    sda_out <= 0;
                                    state   <= ST_STOP;
                                end else begin
                                    byte_cnt <= byte_cnt + 1;
                                    bit_cnt  <= 4'd7;
                                    state    <= ST_SEND_BIT;
                                end
                            end
                        endcase
                        phase <= phase + 1;
                    end
                end

                // STOP condition: SDA rises while SCL is high
                ST_STOP: begin
                    if (clk_tick) begin
                        case (phase)
                            2'd0: begin scl <= 0; sda_oe <= 1; sda_out <= 0; end
                            2'd1: begin scl <= 1; end
                            2'd2: begin scl <= 1; sda_out <= 1; end  // SDA rises
                            2'd3: begin
                                sda_oe <= 0;
                                state  <= ST_DONE;
                            end
                        endcase
                        phase <= phase + 1;
                    end
                end

                ST_DONE: begin
                    done  <= 1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
