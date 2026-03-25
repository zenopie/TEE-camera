//======================================================================
// hdmi_out.v — 640x480@60Hz HDMI output
//
// Uses exact PLL + llhdmi + TMDS_encoder from working iCESugar-Pro
// reference: github.com/wuxx/icesugar-pro/src/hdmi_test_pattern/
//======================================================================
`default_nettype none

module hdmi_out (
    input  wire        clk_25,
    input  wire        rst_n,

    output wire [9:0]  pixel_x,
    output wire [9:0]  pixel_y,
    output wire        pixel_active,
    input  wire [7:0]  red,
    input  wire [7:0]  green,
    input  wire [7:0]  blue,

    output wire        pix_clk,

    output wire [3:0]  hdmi_p,
    output wire [3:0]  hdmi_n
);

    //================================================================
    // PLL — exact from working reference
    //================================================================
    wire clk_125MHz, clk_250MHz, clk_25MHz;

    (* ICP_CURRENT="9" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .CLKOS3_CPHASE(5), .CLKOS2_CPHASE(0),
        .CLKOS_CPHASE(1), .CLKOP_CPHASE(3),
        .OUTDIVIDER_MUXD("DIVD"), .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXB("DIVB"), .OUTDIVIDER_MUXA("DIVA"),
        .CLKOS3_ENABLE("DISABLED"), .CLKOS2_ENABLE("ENABLED"),
        .CLKOS_ENABLE("ENABLED"), .CLKOP_ENABLE("ENABLED"),
        .CLKOS3_DIV(1), .CLKOS2_DIV(20),
        .CLKOS_DIV(2), .CLKOP_DIV(4),
        .CLKFB_DIV(5), .CLKI_DIV(1),
        .FEEDBK_PATH("CLKOP")
    ) pll_i (
        .CLKI(clk_25), .CLKFB(clk_125MHz),
        .CLKOP(clk_125MHz), .CLKOS(clk_250MHz), .CLKOS2(clk_25MHz),
        .RST(1'b0), .STDBY(1'b0),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b0), .PHASESTEP(1'b0),
        .PLLWAKESYNC(1'b0),
        .ENCLKOP(1'b0), .ENCLKOS(1'b0), .ENCLKOS2(1'b0),
        .LOCK()
    );

    assign pix_clk = clk_25MHz;

    //================================================================
    // Reset
    //================================================================
    reg [2:0] reset_cnt = 0;
    wire reset = ~reset_cnt[2];
    always @(posedge clk_25MHz)
        if (reset) reset_cnt <= reset_cnt + 1;

    //================================================================
    // VGA timing + TMDS + serializer (exact from llhdmi.v reference)
    //================================================================
    reg [9:0] CounterX = 0, CounterY = 0;
    reg hSync, vSync, DrawArea;

    always @(posedge clk_25MHz)
        if (reset) CounterX <= 0;
        else CounterX <= (CounterX == 799) ? 0 : CounterX + 1;

    always @(posedge clk_25MHz)
        if (reset) CounterY <= 0;
        else if (CounterX == 799)
            CounterY <= (CounterY == 524) ? 0 : CounterY + 1;

    always @(posedge clk_25MHz)
        DrawArea <= (CounterX < 640) && (CounterY < 480);

    always @(posedge clk_25MHz)
        hSync <= (CounterX >= 656) && (CounterX < 752);

    always @(posedge clk_25MHz)
        vSync <= (CounterY >= 490) && (CounterY < 492);

    assign pixel_x = CounterX;
    assign pixel_y = CounterY;
    assign pixel_active = (CounterX < 640) && (CounterY < 480);

    // TMDS encoding
    wire [9:0] TMDS_red, TMDS_grn, TMDS_blu;
    TMDS_encoder enc_R(.clk(clk_25MHz), .VD(red),   .CD(2'b00),
                       .VDE(DrawArea), .TMDS(TMDS_red));
    TMDS_encoder enc_G(.clk(clk_25MHz), .VD(green), .CD(2'b00),
                       .VDE(DrawArea), .TMDS(TMDS_grn));
    TMDS_encoder enc_B(.clk(clk_25MHz), .VD(blue),  .CD({vSync, hSync}),
                       .VDE(DrawArea), .TMDS(TMDS_blu));

    // 10:1 serializer — exact from reference
    reg [3:0] TMDS_mod10 = 0;
    reg TMDS_shift_load = 0;
    always @(posedge clk_250MHz) begin
        if (reset) begin
            TMDS_mod10 <= 0;
            TMDS_shift_load <= 0;
        end else begin
            TMDS_mod10 <= (TMDS_mod10 == 4'd9) ? 4'd0 : TMDS_mod10 + 4'd1;
            TMDS_shift_load <= (TMDS_mod10 == 4'd9);
        end
    end

    reg [9:0] TMDS_shift_red = 0, TMDS_shift_grn = 0, TMDS_shift_blu = 0;
    always @(posedge clk_250MHz) begin
        if (reset) begin
            TMDS_shift_red <= 0;
            TMDS_shift_grn <= 0;
            TMDS_shift_blu <= 0;
        end else begin
            TMDS_shift_red <= TMDS_shift_load ? TMDS_red : {1'b0, TMDS_shift_red[9:1]};
            TMDS_shift_grn <= TMDS_shift_load ? TMDS_grn : {1'b0, TMDS_shift_grn[9:1]};
            TMDS_shift_blu <= TMDS_shift_load ? TMDS_blu : {1'b0, TMDS_shift_blu[9:1]};
        end
    end

    // Output — pseudo-differential via OBUFDS pattern
    assign hdmi_p[0] =  TMDS_shift_blu[0];
    assign hdmi_n[0] = ~TMDS_shift_blu[0];
    assign hdmi_p[1] =  TMDS_shift_grn[0];
    assign hdmi_n[1] = ~TMDS_shift_grn[0];
    assign hdmi_p[2] =  TMDS_shift_red[0];
    assign hdmi_n[2] = ~TMDS_shift_red[0];
    assign hdmi_p[3] =  clk_25MHz;
    assign hdmi_n[3] = ~clk_25MHz;

endmodule
