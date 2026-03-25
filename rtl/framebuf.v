//======================================================================
// framebuf.v — 320×240 frame buffer, RGB332 (8 bits per pixel)
// True dual-port: write on DVP clock, read on PLL pixel clock.
// Yosys infers SDP DP16KD with independent clocks.
//======================================================================
`default_nettype none

module framebuf (
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire        wr_en,
    input  wire [16:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire [16:0] rd_addr,
    output reg  [7:0]  rd_data
);

    reg [7:0] mem [0:76799];  // 320×240 RGB332

    always @(posedge wr_clk)
        if (wr_en)
            mem[wr_addr] <= wr_data;

    always @(posedge rd_clk)
        rd_data <= mem[rd_addr];

endmodule
