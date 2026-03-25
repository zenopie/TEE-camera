//======================================================================
// fpga_top.v — FPGA top-level for iCESugar-Pro hardware
//
// Full attestation pipeline with HDMI output:
//   1. Power-on reset, camera power sequencing, SCCB init
//   2. PUF → keygen → Ed25519 public key
//   3. Per-frame: DVP → SHA-512 hash → Ed25519 sign
//   4. HDMI: camera pixels (top) + binary barcode (bottom)
//======================================================================

`default_nettype none

module fpga_top (
    input  wire       clk,          // 25 MHz

    // Camera DVP via P2 header
    input  wire       vsync,
    input  wire       href,
    input  wire       pclk,
    input  wire [7:0] pixel_data,

    // Camera control
    output wire       xclk,         // 25 MHz clock to camera
    output wire       cam_sioc,     // SCCB clock
    inout  wire       cam_siod,     // SCCB data
    output reg        cam_reset_n,  // camera reset (active low)
    output reg        cam_pwdn,     // camera power down (active high)

    // UART (kept for debug)
    output wire       uart_txd,
    input  wire       uart_rxd,

    // HDMI output (pseudo-differential)
    output wire [3:0] hdmi_p,
    output wire [3:0] hdmi_n,

    // RGB LED (active low)
    output reg [2:0]  rgb_led
);

    //----------------------------------------------------------------
    // Power-on reset generator (~10ms at 25 MHz = 250,000 cycles)
    //----------------------------------------------------------------
    reg [17:0] por_cnt;
    reg        rst_n;

    always @(posedge clk) begin
        if (por_cnt != 18'h3FFFF) begin
            por_cnt <= por_cnt + 1;
            rst_n   <= 0;
        end else begin
            rst_n <= 1;
        end
    end

    initial begin
        por_cnt = 0;
        rst_n   = 0;
    end

    //----------------------------------------------------------------
    // XCLK output — drive 25 MHz system clock to camera
    //----------------------------------------------------------------
    assign xclk = clk;

    //----------------------------------------------------------------
    // Camera power sequencing
    //----------------------------------------------------------------
    reg [18:0] cam_delay;
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
                    cam_pwdn    <= 0;
                    cam_reset_n <= 0;
                    cam_delay   <= 19'd500_000;
                    cam_pwr_state <= 2'd1;
                end
                2'd1: begin
                    if (cam_delay == 0) begin
                        cam_reset_n <= 1;
                        cam_delay   <= 19'd500_000;
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
    // UART RX for live camera register tuning
    //----------------------------------------------------------------
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;

    uart_rx #(
        .CLK_FREQ  (25_000_000),
        .BAUD_RATE (9_600)
    ) uart_rx_inst (
        .clk(clk), .rst_n(rst_n),
        .rx(uart_rxd),
        .data(uart_rx_data),
        .valid(uart_rx_valid)
    );

    //----------------------------------------------------------------
    // OV7670 SCCB initialization + live tuning
    //----------------------------------------------------------------
    wire cam_init_done;
    wire cam_init_error;

    ov7670_init cam_init_inst (
        .clk(clk), .rst_n(rst_n),
        .start(cam_init_start),
        .done(cam_init_done),
        .error(cam_init_error),
        .cmd_data(uart_rx_data),
        .cmd_valid(uart_rx_valid),
        .scl(cam_sioc),
        .sda(cam_siod)
    );

    //----------------------------------------------------------------
    // Attestation SoC
    //----------------------------------------------------------------
    wire       attest_boot_done;
    wire       attest_signing;
    wire [7:0] sig_rd_addr;
    wire [7:0] sig_rd_data;

    soc_top #(
        .CLK_FREQ  (25_000_000),
        .BAUD_RATE (9_600)
    ) attest_inst (
        .clk         (clk),
        .rst_n       (rst_n),
        .vsync       (vsync),
        .href        (href),
        .pixel_data  (pixel_data),
        .uart_txd    (uart_txd),
        .uart_rxd    (uart_rxd),
        .boot_done   (attest_boot_done),
        .signing     (attest_signing),
        .sig_rd_addr (sig_rd_addr),
        .sig_rd_data (sig_rd_data)
    );

    //----------------------------------------------------------------
    // Frame buffer (RGB332, 320×240, 1 byte per pixel)
    //----------------------------------------------------------------
    reg         fb_wr_en;
    reg  [16:0] fb_wr_addr;
    reg  [7:0]  fb_wr_data;
    wire [16:0] fb_rd_addr;
    wire [7:0]  fb_rd_data;

    framebuf fb_inst (
        .wr_clk  (pclk),       // camera pixel clock — DVP domain
        .rd_clk  (hdmi_pclk),  // PLL 25 MHz — HDMI pixel domain
        .wr_en   (fb_wr_en),
        .wr_addr (fb_wr_addr),
        .wr_data (fb_wr_data),
        .rd_addr (fb_rd_addr),
        .rd_data (fb_rd_data)
    );

    //----------------------------------------------------------------
    // DVP capture → frame buffer (on pclk — camera pixel clock)
    //
    // Camera outputs VGA (640×480) RGB565. We decimate to 320×240:
    //   - Skip every other line (odd lines)
    //   - Skip every other pixel (4-byte cycle: 2 bytes keep, 2 bytes skip)
    // RGB565: 2 bytes per pixel
    //   Byte 0 (high): RRRRR_GGG  (R[4:0], G[5:3])
    //   Byte 1 (low):  GGG_BBBBB  (G[2:0], B[4:0])
    // Pack to RGB332: {hi[7:5], hi[2:0], lo[4:3]}
    //----------------------------------------------------------------
    reg [1:0]  dvp_phase;       // 0=hi(keep), 1=lo(keep), 2=hi(skip), 3=lo(skip)
    reg [7:0]  dvp_hi;          // stashed high byte (RRRRRGGG)
    reg        dvp_pixel_rdy;   // pixel ready flag
    reg        vsync_prev_fb;
    reg        href_prev;
    reg [9:0]  line_count;
    wire       line_active = ~line_count[0];  // even lines only

    // RGB565 → RGB332 (combinational, from registered bytes)
    // OV7670 byte order: Byte0={R[4:0],G[5:3]}=RRRRRGGG, Byte1={G[2:0],B[4:0]}=GGGBBBBB
    reg  [7:0] dvp_lo;
    wire [7:0] rgb332 = {dvp_hi[7:5], dvp_hi[2:0], dvp_lo[4:3]};

    always @(posedge pclk) begin
        // Increment address the cycle AFTER a write completes
        if (fb_wr_en)
            fb_wr_addr <= fb_wr_addr + 1;

        fb_wr_en  <= 0;
        vsync_prev_fb <= vsync;
        href_prev <= href;

        // VSYNC falling edge = start of new frame
        if (!vsync && vsync_prev_fb) begin
            fb_wr_addr    <= 0;
            dvp_phase     <= 0;
            line_count    <= 0;
            dvp_pixel_rdy <= 0;
        end else if (href) begin
            dvp_phase <= dvp_phase + 1;  // wraps 0→1→2→3→0
            case (dvp_phase)
                2'd0: begin              // High byte of keep-pixel; write previous pixel
                    if (dvp_pixel_rdy && line_active) begin
                        fb_wr_en <= 1'b1;
                        fb_wr_data <= rgb332;
                    end
                    dvp_hi <= pixel_data;
                    dvp_pixel_rdy <= 0;
                end
                2'd1: begin              // Low byte of keep-pixel → pixel ready
                    dvp_lo <= pixel_data;
                    dvp_pixel_rdy <= 1;
                end
                2'd2: ;                  // High byte of skip-pixel
                2'd3: ;                  // Low byte of skip-pixel
            endcase
        end else begin
            // Write last pixel of line if pending
            if (dvp_pixel_rdy && line_active) begin
                fb_wr_en <= 1'b1;
                fb_wr_data <= rgb332;
            end
            dvp_pixel_rdy <= 0;
            dvp_phase     <= 0;
            // HREF falling edge = end of line
            if (href_prev && !href)
                line_count <= line_count + 1;
        end
    end

    //----------------------------------------------------------------
    // HDMI output — 640x480@60Hz
    // All pixel generation runs on PLL pixel clock (hdmi_pclk)
    //----------------------------------------------------------------
    wire [9:0] hdmi_x, hdmi_y;
    wire       hdmi_active;
    reg  [7:0] hdmi_r, hdmi_g, hdmi_b;
    wire       hdmi_pclk;

    hdmi_out hdmi_inst (
        .clk_25       (clk),
        .rst_n        (rst_n),
        .pixel_x      (hdmi_x),
        .pixel_y      (hdmi_y),
        .pixel_active (hdmi_active),
        .red          (hdmi_r),
        .green        (hdmi_g),
        .blue         (hdmi_b),
        .pix_clk      (hdmi_pclk),
        .hdmi_p       (hdmi_p),
        .hdmi_n       (hdmi_n)
    );

    //----------------------------------------------------------------
    // HDMI pixel generation (ALL on PLL pixel clock)
    //
    // Layout:
    //   Rows 0-439:   Camera (220 cam rows × 2, 320 cols × 2)
    //   Rows 440-443: Sync pattern (alternating 4px B/W blocks)
    //   Rows 444-479: Binary barcode (9 rows × 4px, 164 bytes data)
    //----------------------------------------------------------------

    // BRAM address from PLL-domain counters (BRAM also on PLL clock)
    // RGB332: 1 byte per pixel, row stride = 320
    // addr = cam_row * 320 + cam_col = cam_row * 256 + cam_row * 64 + cam_col
    wire [8:0] cam_row = hdmi_y[9:1];
    wire [8:0] cam_col = hdmi_x[9:1];
    assign fb_rd_addr = ({8'd0, cam_row} << 8) + ({8'd0, cam_row} << 6)
                      + {8'd0, cam_col};

    // Expand RGB332 to RGB888 (replicate bits for full range)
    wire [7:0] cam_r = {fb_rd_data[7:5], fb_rd_data[7:5], fb_rd_data[7:6]};
    wire [7:0] cam_g = {fb_rd_data[4:2], fb_rd_data[4:2], fb_rd_data[4:3]};
    wire [7:0] cam_b = {fb_rd_data[1:0], fb_rd_data[1:0], fb_rd_data[1:0], fb_rd_data[1:0]};

    // Barcode region: read from signature register file
    wire [3:0] barcode_data_row = (hdmi_y - 10'd444) >> 2;
    wire [7:0] barcode_bit_col  = hdmi_x[9:2];
    wire [7:0] barcode_byte_idx = {4'd0, barcode_data_row} * 8'd20
                                + barcode_bit_col[7:3];
    wire [2:0] barcode_bit_pos  = 3'd7 - barcode_bit_col[2:0];

    assign sig_rd_addr = barcode_byte_idx;
    wire barcode_bit = (barcode_byte_idx < 8'd164) ? sig_rd_data[barcode_bit_pos] : 1'b0;
    wire [7:0] barcode_pixel = barcode_bit ? 8'hFF : 8'h00;

    // Pixel mux — delayed one cycle on PLL clock to match BRAM latency
    reg [9:0] hdmi_y_d, hdmi_x_d;
    always @(posedge hdmi_pclk) begin
        hdmi_y_d <= hdmi_y;
        hdmi_x_d <= hdmi_x;
    end

    always @* begin
        if (hdmi_y_d < 10'd440) begin
            // Camera region — RGB from frame buffer
            hdmi_r = cam_r;
            hdmi_g = cam_g;
            hdmi_b = cam_b;
        end else if (hdmi_y_d < 10'd444) begin
            // Sync pattern — alternating 4px B/W blocks
            hdmi_r = hdmi_x_d[2] ? 8'hFF : 8'h00;
            hdmi_g = hdmi_x_d[2] ? 8'hFF : 8'h00;
            hdmi_b = hdmi_x_d[2] ? 8'hFF : 8'h00;
        end else if (hdmi_y_d < 10'd480) begin
            // Barcode
            hdmi_r = barcode_pixel;
            hdmi_g = barcode_pixel;
            hdmi_b = barcode_pixel;
        end else begin
            hdmi_r = 8'h00;
            hdmi_g = 8'h00;
            hdmi_b = 8'h00;
        end
    end

    //----------------------------------------------------------------
    // LED status
    //----------------------------------------------------------------
    reg [23:0] blink_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            rgb_led   <= 3'b111;
            blink_cnt <= 0;
        end else begin
            blink_cnt <= blink_cnt + 1;

            if (!cam_init_done)
                rgb_led <= 3'b110;                          // red: camera init
            else if (cam_init_error)
                rgb_led <= 3'b100;                          // yellow: SCCB error
            else if (attest_signing)
                rgb_led <= {2'b10, blink_cnt[22]};          // green blink: signing
            else if (attest_boot_done)
                rgb_led <= 3'b101;                          // green: ready
            else
                rgb_led <= {1'b1, blink_cnt[23], 1'b1};    // green pulse: keygen
        end
    end

endmodule
