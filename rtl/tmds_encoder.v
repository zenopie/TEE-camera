// TMDS encoder for DVI/HDMI
// (c) fpga4fun.com & KNJN LLC 2013
`default_nettype none

module TMDS_encoder(
    input  wire       clk,
    input  wire [7:0] VD,   // video data
    input  wire [1:0] CD,   // control data
    input  wire       VDE,  // video data enable
    output reg  [9:0] TMDS = 0
);

wire [3:0] Nb1s = {3'b0, VD[0]} + {3'b0, VD[1]} + {3'b0, VD[2]}
    + {3'b0, VD[3]} + {3'b0, VD[4]} + {3'b0, VD[5]}
    + {3'b0, VD[6]} + {3'b0, VD[7]};
wire XNOR = (Nb1s > 4'd4) || (Nb1s == 4'd4 && VD[0] == 1'b0);

wire QM0 = VD[0];
wire QM1 = QM0 ^ VD[1] ^ XNOR;
wire QM2 = QM1 ^ VD[2] ^ XNOR;
wire QM3 = QM2 ^ VD[3] ^ XNOR;
wire QM4 = QM3 ^ VD[4] ^ XNOR;
wire QM5 = QM4 ^ VD[5] ^ XNOR;
wire QM6 = QM5 ^ VD[6] ^ XNOR;
wire QM7 = QM6 ^ VD[7] ^ XNOR;
wire QM8 = ~XNOR;
wire [8:0] q_m = {QM8, QM7, QM6, QM5, QM4, QM3, QM2, QM1, QM0};

reg [3:0] balance_acc = 0;
wire [3:0] balance = {3'b0, q_m[0]} + {3'b0, q_m[1]} + {3'b0, q_m[2]}
    + {3'b0, q_m[3]} + {3'b0, q_m[4]} + {3'b0, q_m[5]}
    + {3'b0, q_m[6]} + {3'b0, q_m[7]} - 4'd4;
wire balance_sign_eq = (balance[3] == balance_acc[3]);
wire invert_q_m = (balance == 0 || balance_acc == 0) ? ~q_m[8] : balance_sign_eq;

wire [3:0] balance_acc_inc = balance
    - {3'b0, ({q_m[8] ^ ~balance_sign_eq} & ~(balance == 0 || balance_acc == 0))};
wire [3:0] balance_acc_new = invert_q_m ? balance_acc - balance_acc_inc
                                        : balance_acc + balance_acc_inc;
wire [9:0] TMDS_data = {invert_q_m, q_m[8], q_m[7:0] ^ {8{invert_q_m}}};
wire [9:0] TMDS_code = CD[1] ? (CD[0] ? 10'b1010101011 : 10'b0101010100)
                              : (CD[0] ? 10'b0010101011 : 10'b1101010100);

always @(posedge clk) TMDS <= VDE ? TMDS_data : TMDS_code;
always @(posedge clk) balance_acc <= VDE ? balance_acc_new : 4'h0;

endmodule
