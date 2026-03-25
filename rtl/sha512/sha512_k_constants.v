//======================================================================
//
// sha512_k_constants.v
// --------------------
// The table K with constants in the SHA-512 hash function.
// Synchronous ROM — Yosys infers EBR on ECP5, saving ~1500 LUT4s.
//
// Original Author: Joachim Strombergson
// Copyright (c) 2014 Secworks Sweden AB
// Modified: synchronous read for EBR inference
//
//======================================================================

`default_nettype none

module sha512_k_constants(
                          input wire            clk,
                          input wire  [6 : 0]   addr,
                          output reg  [63 : 0]  K
                         );

  reg [63:0] rom [0:79];

  initial begin
    rom[0]  = 64'h428a2f98d728ae22;
    rom[1]  = 64'h7137449123ef65cd;
    rom[2]  = 64'hb5c0fbcfec4d3b2f;
    rom[3]  = 64'he9b5dba58189dbbc;
    rom[4]  = 64'h3956c25bf348b538;
    rom[5]  = 64'h59f111f1b605d019;
    rom[6]  = 64'h923f82a4af194f9b;
    rom[7]  = 64'hab1c5ed5da6d8118;
    rom[8]  = 64'hd807aa98a3030242;
    rom[9]  = 64'h12835b0145706fbe;
    rom[10] = 64'h243185be4ee4b28c;
    rom[11] = 64'h550c7dc3d5ffb4e2;
    rom[12] = 64'h72be5d74f27b896f;
    rom[13] = 64'h80deb1fe3b1696b1;
    rom[14] = 64'h9bdc06a725c71235;
    rom[15] = 64'hc19bf174cf692694;
    rom[16] = 64'he49b69c19ef14ad2;
    rom[17] = 64'hefbe4786384f25e3;
    rom[18] = 64'h0fc19dc68b8cd5b5;
    rom[19] = 64'h240ca1cc77ac9c65;
    rom[20] = 64'h2de92c6f592b0275;
    rom[21] = 64'h4a7484aa6ea6e483;
    rom[22] = 64'h5cb0a9dcbd41fbd4;
    rom[23] = 64'h76f988da831153b5;
    rom[24] = 64'h983e5152ee66dfab;
    rom[25] = 64'ha831c66d2db43210;
    rom[26] = 64'hb00327c898fb213f;
    rom[27] = 64'hbf597fc7beef0ee4;
    rom[28] = 64'hc6e00bf33da88fc2;
    rom[29] = 64'hd5a79147930aa725;
    rom[30] = 64'h06ca6351e003826f;
    rom[31] = 64'h142929670a0e6e70;
    rom[32] = 64'h27b70a8546d22ffc;
    rom[33] = 64'h2e1b21385c26c926;
    rom[34] = 64'h4d2c6dfc5ac42aed;
    rom[35] = 64'h53380d139d95b3df;
    rom[36] = 64'h650a73548baf63de;
    rom[37] = 64'h766a0abb3c77b2a8;
    rom[38] = 64'h81c2c92e47edaee6;
    rom[39] = 64'h92722c851482353b;
    rom[40] = 64'ha2bfe8a14cf10364;
    rom[41] = 64'ha81a664bbc423001;
    rom[42] = 64'hc24b8b70d0f89791;
    rom[43] = 64'hc76c51a30654be30;
    rom[44] = 64'hd192e819d6ef5218;
    rom[45] = 64'hd69906245565a910;
    rom[46] = 64'hf40e35855771202a;
    rom[47] = 64'h106aa07032bbd1b8;
    rom[48] = 64'h19a4c116b8d2d0c8;
    rom[49] = 64'h1e376c085141ab53;
    rom[50] = 64'h2748774cdf8eeb99;
    rom[51] = 64'h34b0bcb5e19b48a8;
    rom[52] = 64'h391c0cb3c5c95a63;
    rom[53] = 64'h4ed8aa4ae3418acb;
    rom[54] = 64'h5b9cca4f7763e373;
    rom[55] = 64'h682e6ff3d6b2b8a3;
    rom[56] = 64'h748f82ee5defb2fc;
    rom[57] = 64'h78a5636f43172f60;
    rom[58] = 64'h84c87814a1f0ab72;
    rom[59] = 64'h8cc702081a6439ec;
    rom[60] = 64'h90befffa23631e28;
    rom[61] = 64'ha4506cebde82bde9;
    rom[62] = 64'hbef9a3f7b2c67915;
    rom[63] = 64'hc67178f2e372532b;
    rom[64] = 64'hca273eceea26619c;
    rom[65] = 64'hd186b8c721c0c207;
    rom[66] = 64'heada7dd6cde0eb1e;
    rom[67] = 64'hf57d4f7fee6ed178;
    rom[68] = 64'h06f067aa72176fba;
    rom[69] = 64'h0a637dc5a2c898a6;
    rom[70] = 64'h113f9804bef90dae;
    rom[71] = 64'h1b710b35131c471b;
    rom[72] = 64'h28db77f523047d84;
    rom[73] = 64'h32caab7b40c72493;
    rom[74] = 64'h3c9ebe0a15c9bebc;
    rom[75] = 64'h431d67c49c100d4c;
    rom[76] = 64'h4cc5d4becb3e42b6;
    rom[77] = 64'h597f299cfc657e2a;
    rom[78] = 64'h5fcb6fab3ad6faec;
    rom[79] = 64'h6c44198c4a475817;
  end

  always @(posedge clk)
    K <= rom[addr];

endmodule // sha512_k_constants
