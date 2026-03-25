//======================================================================
// ov7670_init.v — OV7670 camera register initialization + live tuning
//
// Walks through a ROM of {reg_addr, reg_data} pairs and sends
// each one via SCCB. After init, accepts live register writes
// via UART (2-byte commands: addr, data).
//======================================================================

`default_nettype none

module ov7670_init (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start,       // pulse to begin initialization
    output reg        done,        // high when all registers written
    output reg        error,       // high if any SCCB NACK

    // UART command interface (active after init done)
    input  wire [7:0] cmd_data,    // UART received byte
    input  wire       cmd_valid,   // UART byte ready pulse

    // SCCB pins
    output wire       scl,
    inout  wire       sda
);

    // OV7670 SCCB write address
    localparam SLAVE_ADDR = 8'h42;

    //----------------------------------------------------------------
    // Register ROM — {addr, data} pairs
    //----------------------------------------------------------------
    localparam NUM_REGS = 23;

    reg [15:0] reg_rom [0:NUM_REGS-1];

    initial begin
        //                addr   data
        reg_rom[ 0] = {8'h12, 8'h80};  // COM7: software reset
        // After reset, wait handled by delay counter below
        reg_rom[ 1] = {8'h12, 8'h04};  // COM7: VGA mode, RGB output
        reg_rom[ 2] = {8'h11, 8'h01};  // CLKRC: clock divider
        reg_rom[ 3] = {8'h0C, 8'h00};  // COM3: no DCW
        reg_rom[ 4] = {8'h3E, 8'h00};  // COM14: no PCLK scaling
        reg_rom[ 5] = {8'h3A, 8'h04};  // TSLB: default byte order
        reg_rom[ 6] = {8'h15, 8'h00};  // COM10: VSYNC positive, HREF default
        reg_rom[ 7] = {8'h13, 8'hE5};  // COM8: AGC + AEC enabled, AWB OFF
        reg_rom[ 8] = {8'h40, 8'hD0};  // COM15: full range + RGB565
        reg_rom[ 9] = {8'h1E, 8'h37};  // MVFP: mirror + flip
        reg_rom[10] = {8'h14, 8'h18};  // COM9: AGC gain ceiling 4x
        reg_rom[11] = {8'h3D, 8'hC0};  // COM13: gamma enable, UV auto adjust
        reg_rom[12] = {8'h04, 8'h00};  // COM1: no CCIR656
        reg_rom[13] = {8'h17, 8'h11};  // HSTART: default
        reg_rom[14] = {8'h18, 8'h61};  // HSTOP: default
        // RGB color matrix (from Linux kernel ov7670 driver)
        reg_rom[15] = {8'h4F, 8'hB3};  // MTX1
        reg_rom[16] = {8'h50, 8'hB3};  // MTX2
        reg_rom[17] = {8'h51, 8'h00};  // MTX3
        reg_rom[18] = {8'h52, 8'h3D};  // MTX4
        reg_rom[19] = {8'h53, 8'hA7};  // MTX5
        reg_rom[20] = {8'h54, 8'hE4};  // MTX6
        reg_rom[21] = {8'h58, 8'h9E};  // MTXS (matrix sign)
        reg_rom[22] = {8'hB0, 8'h84};  // undocumented: required for proper color
    end

    //----------------------------------------------------------------
    // SCCB master instance
    //----------------------------------------------------------------
    reg        sccb_start;
    reg  [7:0] sccb_reg_addr;
    reg  [7:0] sccb_reg_data;
    wire       sccb_done;
    wire       sccb_ack_error;

    sccb_master #(.CLK_DIV(64)) sccb_inst (
        .clk(clk), .rst_n(rst_n),
        .slave_addr(SLAVE_ADDR),
        .reg_addr(sccb_reg_addr),
        .reg_data(sccb_reg_data),
        .start(sccb_start),
        .done(sccb_done),
        .ack_error(sccb_ack_error),
        .scl(scl),
        .sda(sda)
    );

    //----------------------------------------------------------------
    // State machine: init ROM walk + live UART command handler
    //----------------------------------------------------------------
    localparam ST_IDLE    = 3'd0;
    localparam ST_DELAY   = 3'd1;
    localparam ST_LOAD    = 3'd2;
    localparam ST_SEND    = 3'd3;
    localparam ST_WAIT    = 3'd4;
    localparam ST_LISTEN  = 3'd5;  // listen for UART commands
    localparam ST_CMD_SEND = 3'd6;
    localparam ST_CMD_WAIT = 3'd7;

    reg [2:0]  state;
    reg [4:0]  reg_idx;
    reg [19:0] delay_cnt;
    reg        cmd_have_addr;  // have first byte (addr) of command
    reg [7:0]  cmd_addr_reg;   // buffered command address

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            done          <= 0;
            error         <= 0;
            sccb_start    <= 0;
            sccb_reg_addr <= 0;
            sccb_reg_data <= 0;
            reg_idx       <= 0;
            delay_cnt     <= 0;
            cmd_have_addr <= 0;
            cmd_addr_reg  <= 0;
        end else begin
            sccb_start <= 0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        reg_idx <= 0;
                        done    <= 0;
                        error   <= 0;
                        state   <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    sccb_reg_addr <= reg_rom[reg_idx][15:8];
                    sccb_reg_data <= reg_rom[reg_idx][7:0];
                    state         <= ST_SEND;
                end

                ST_SEND: begin
                    sccb_start <= 1;
                    state      <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (sccb_done) begin
                        if (sccb_ack_error)
                            error <= 1;

                        if (reg_idx == 0) begin
                            delay_cnt <= 20'd1_000_000;
                            state     <= ST_DELAY;
                        end else if (reg_idx == NUM_REGS - 1) begin
                            done          <= 1;
                            cmd_have_addr <= 0;
                            state         <= ST_LISTEN;
                        end else begin
                            delay_cnt <= 20'd2500;
                            state     <= ST_DELAY;
                        end
                        reg_idx <= reg_idx + 1;
                    end
                end

                ST_DELAY: begin
                    if (delay_cnt == 0)
                        state <= ST_LOAD;
                    else
                        delay_cnt <= delay_cnt - 1;
                end

                // After init: listen for 2-byte UART commands (addr, data)
                ST_LISTEN: begin
                    if (cmd_valid) begin
                        if (!cmd_have_addr) begin
                            cmd_addr_reg  <= cmd_data;
                            cmd_have_addr <= 1;
                        end else begin
                            sccb_reg_addr <= cmd_addr_reg;
                            sccb_reg_data <= cmd_data;
                            cmd_have_addr <= 0;
                            state         <= ST_CMD_SEND;
                        end
                    end
                end

                ST_CMD_SEND: begin
                    sccb_start <= 1;
                    state      <= ST_CMD_WAIT;
                end

                ST_CMD_WAIT: begin
                    if (sccb_done)
                        state <= ST_LISTEN;
                end
            endcase
        end
    end

endmodule
