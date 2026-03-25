// blink.v — RGB LED blink test for iCESugar-Pro
// Only the RGB LED (A11, A12, B11) is on the module.

`default_nettype none

module blink (
    input  wire       clk,       // 25 MHz
    output reg  [2:0] rgb_led    // RGB LED (active low: 0=on, 1=off)
);

    reg [25:0] counter;

    always @(posedge clk)
        counter <= counter + 1;

    // Cycle: Red → Green → Blue → Yellow → Cyan → Magenta → White → Off
    // Changes every ~1.3 seconds (25MHz / 2^25)
    always @(posedge clk)
        rgb_led <= ~counter[25:23];

endmodule
