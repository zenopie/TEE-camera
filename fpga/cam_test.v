//======================================================================
// cam_test.v — OV7670 connectivity test for iCESugar-Pro
//
// Tests solder connections by checking:
//   1. SCCB write ACK (validates: power, XCLK, SIOC, SIOD, RESET, PWDN)
//   2. VSYNC edge count (validates: camera outputting frames)
//   3. Pixel data activity (validates: D[7:0] lines)
//
// LED status (active low on iCESugar-Pro):
//   Red (brief) = SCCB init in progress
//   Yellow      = SCCB failed (check power/SIOC/SIOD wiring)
//   Blue        = SCCB OK, no VSYNC (check VSYNC wiring)
//   Red (solid) = VSYNC ok but no pixel data (check D lines)
//   Green       = ALL GOOD: SCCB + VSYNC + pixel data
//
// UART output (115200 8N1):
//   "SCCB OK\r\n" or "SCCB ER\r\n"  after init
//   "V:XXXX D:XX\r\n"               every ~2 seconds
//     V = VSYNC rising edge count (hex)
//     D = OR of all pixel bytes seen during HREF (hex)
//         0xFF means all 8 data lines active
//         0x00 means no pixel data seen
//======================================================================

`default_nettype none

module cam_test (
    input  wire       clk,          // 25 MHz
    input  wire       vsync,
    input  wire       href,
    input  wire       pclk,
    input  wire [7:0] pixel_data,
    output wire       xclk,
    output wire       cam_sioc,
    inout  wire       cam_siod,
    output reg        cam_reset_n,
    output reg        cam_pwdn,
    output wire       uart_txd,
    input  wire       uart_rxd,
    output reg  [2:0] rgb_led
);

    //----------------------------------------------------------------
    // Hex character helper
    //----------------------------------------------------------------
    function [7:0] hx;
        input [3:0] v;
        if (v < 4'd10) hx = 8'h30 | {4'd0, v};
        else           hx = 8'h37 + {4'd0, v};
    endfunction

    //----------------------------------------------------------------
    // Power-on reset (~10ms at 25 MHz)
    //----------------------------------------------------------------
    reg [17:0] por_cnt = 0;
    reg        rst_n   = 0;

    always @(posedge clk) begin
        if (por_cnt != 18'h3FFFF) begin
            por_cnt <= por_cnt + 1;
            rst_n   <= 0;
        end else
            rst_n <= 1;
    end

    //----------------------------------------------------------------
    // XCLK — drive 25 MHz to camera
    //----------------------------------------------------------------
    assign xclk = clk;

    //----------------------------------------------------------------
    // Camera power sequencing
    //----------------------------------------------------------------
    reg [19:0] cam_delay;
    reg        cam_init_start;
    reg [1:0]  cam_pwr_state;

    always @(posedge clk) begin
        if (!rst_n) begin
            cam_pwdn       <= 1;
            cam_reset_n    <= 0;
            cam_delay      <= 0;
            cam_pwr_state  <= 0;
            cam_init_start <= 0;
        end else begin
            cam_init_start <= 0;
            case (cam_pwr_state)
                2'd0: begin
                    cam_pwdn    <= 0;          // release power-down
                    cam_reset_n <= 0;          // hold reset
                    cam_delay   <= 20'd500_000; // 20ms
                    cam_pwr_state <= 2'd1;
                end
                2'd1: begin
                    if (cam_delay == 0) begin
                        cam_reset_n <= 1;          // release reset
                        cam_delay   <= 20'd500_000; // 20ms startup
                        cam_pwr_state <= 2'd2;
                    end else
                        cam_delay <= cam_delay - 1;
                end
                2'd2: begin
                    if (cam_delay == 0) begin
                        cam_init_start <= 1;
                        cam_pwr_state  <= 2'd3;
                    end else
                        cam_delay <= cam_delay - 1;
                end
                2'd3: ;
            endcase
        end
    end

    //----------------------------------------------------------------
    // OV7670 SCCB initialization
    //----------------------------------------------------------------
    wire cam_init_done, cam_init_error;

    ov7670_init cam_init_inst (
        .clk(clk), .rst_n(rst_n),
        .start(cam_init_start),
        .done(cam_init_done), .error(cam_init_error),
        .scl(cam_sioc), .sda(cam_siod)
    );

    //----------------------------------------------------------------
    // VSYNC rising-edge counter
    //----------------------------------------------------------------
    reg        vsync_prev;
    reg [15:0] vsync_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            vsync_prev <= 0;
            vsync_cnt  <= 0;
        end else begin
            vsync_prev <= vsync;
            if (vsync && !vsync_prev)
                vsync_cnt <= vsync_cnt + 1;
        end
    end

    //----------------------------------------------------------------
    // Pixel data activity accumulator
    // OR of all pixel bytes seen during HREF — shows which data
    // lines have toggled. 0xFF = all 8 lines active.
    //----------------------------------------------------------------
    reg [7:0] pixel_or;

    always @(posedge clk) begin
        if (!rst_n)
            pixel_or <= 0;
        else if (href)
            pixel_or <= pixel_or | pixel_data;
    end

    //----------------------------------------------------------------
    // UART TX
    //----------------------------------------------------------------
    reg  [7:0] tx_byte;
    reg        tx_send;
    wire       tx_busy;

    uart_tx #(.CLK_FREQ(25_000_000), .BAUD_RATE(115200)) tx_inst (
        .clk(clk), .rst_n(rst_n),
        .data(tx_byte), .send(tx_send),
        .tx(uart_txd), .busy(tx_busy)
    );

    //----------------------------------------------------------------
    // Send engine — shifts out bytes from 128-bit buffer (max 16)
    //----------------------------------------------------------------
    reg [127:0] send_buf;
    reg [4:0]   send_len;
    reg         send_active;

    //----------------------------------------------------------------
    // Main FSM
    //----------------------------------------------------------------
    localparam ST_WAIT_INIT  = 3'd0;
    localparam ST_SEND_SCCB  = 3'd1;
    localparam ST_SEND       = 3'd2;
    localparam ST_WAIT_FRAMES = 3'd3;
    localparam ST_SEND_STATS = 3'd4;
    localparam ST_DONE       = 3'd5;

    reg [2:0]  state;
    reg [2:0]  send_return;
    reg [25:0] timer;
    reg        sccb_ok;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_WAIT_INIT;
            send_buf    <= 0;
            send_len    <= 0;
            send_active <= 0;
            send_return <= ST_WAIT_INIT;
            tx_byte     <= 0;
            tx_send     <= 0;
            timer       <= 0;
            sccb_ok     <= 0;
            rgb_led     <= 3'b111; // all off
        end else begin
            tx_send <= 0;

            case (state)
                // ── Wait for SCCB init ──
                ST_WAIT_INIT: begin
                    rgb_led <= 3'b110; // red
                    if (cam_init_done) begin
                        sccb_ok <= !cam_init_error;
                        state   <= ST_SEND_SCCB;
                    end
                end

                // ── Report SCCB result ──
                ST_SEND_SCCB: begin
                    if (sccb_ok) begin
                        // "SCCB OK\r\n" = 9 bytes, pad to 128 bits
                        send_buf <= {"SCCB OK", 8'h0D, 8'h0A, 56'd0};
                        send_len <= 5'd9;
                    end else begin
                        // "SCCB ER\r\n" = 9 bytes
                        send_buf <= {"SCCB ER", 8'h0D, 8'h0A, 56'd0};
                        send_len <= 5'd9;
                    end
                    send_active <= 1;
                    send_return <= ST_WAIT_FRAMES;
                    state       <= ST_SEND;
                    timer       <= 0;
                end

                // ── Byte-by-byte send engine ──
                ST_SEND: begin
                    if (send_active && !tx_busy && !tx_send) begin
                        tx_byte  <= send_buf[127:120];
                        tx_send  <= 1;
                        send_buf <= {send_buf[119:0], 8'd0};
                        send_len <= send_len - 1;
                        if (send_len == 5'd1)
                            send_active <= 0;
                    end
                    if (!send_active)
                        state <= send_return;
                end

                // ── Wait ~2 sec for camera to produce frames ──
                ST_WAIT_FRAMES: begin
                    rgb_led <= sccb_ok ? 3'b101 : 3'b100;  // green or yellow
                    timer   <= timer + 1;
                    if (timer == 26'd50_000_000)  // 2 sec at 25 MHz
                        state <= ST_SEND_STATS;
                end

                // ── Report VSYNC count + pixel activity ──
                ST_SEND_STATS: begin
                    // "V:XXXX D:XX\r\n" = 13 bytes
                    send_buf <= {
                        8'h56, 8'h3A,                               // "V:"
                        hx(vsync_cnt[15:12]), hx(vsync_cnt[11:8]),
                        hx(vsync_cnt[7:4]),   hx(vsync_cnt[3:0]),
                        8'h20, 8'h44, 8'h3A,                       // " D:"
                        hx(pixel_or[7:4]),    hx(pixel_or[3:0]),
                        8'h0D, 8'h0A,                              // "\r\n"
                        24'd0
                    };
                    send_len    <= 5'd13;
                    send_active <= 1;
                    send_return <= ST_DONE;
                    state       <= ST_SEND;
                    timer       <= 0;
                end

                // ── Done: show final LED, periodic re-report ──
                ST_DONE: begin
                    // LED based on results
                    if (sccb_ok && vsync_cnt != 0 && pixel_or != 0)
                        rgb_led <= 3'b101;              // green = ALL GOOD
                    else if (sccb_ok && vsync_cnt != 0)
                        rgb_led <= 3'b110;              // red = frames but no pixel data
                    else if (sccb_ok)
                        rgb_led <= 3'b011;              // blue = SCCB ok, no VSYNC
                    else
                        rgb_led <= 3'b100;              // yellow = SCCB failed

                    // Re-send stats every ~2 sec
                    timer <= timer + 1;
                    if (timer == 26'd50_000_000) begin
                        timer <= 0;
                        state <= ST_SEND_STATS;
                    end
                end
            endcase
        end
    end

endmodule
