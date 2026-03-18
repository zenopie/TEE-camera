//======================================================================
//
// fe25519.v
// ---------
// Field element arithmetic modulo p = 2^255 - 19.
// Operations: add, sub, mul (mod p).
//
// Behavioral implementation for simulation. Hardware synthesis
// version will use iCE40UP5K DSP blocks (SB_MAC16) for the
// multiplier with iterative 16-bit limb schoolbook algorithm.
//
// Interface is sequential: assert start with op/a/b, wait for done.
//
// Copyright (c) 2024 TEE-camera project
// Open source under MIT license
//
//======================================================================

`default_nettype none

module fe25519 (
    input  wire         clk,
    input  wire         reset_n,
    input  wire [1:0]   op,        // 00=add, 01=sub, 10=mul
    input  wire [254:0] a,
    input  wire [254:0] b,
    input  wire         start,
    output reg  [254:0] result,
    output reg          done
);

    // p = 2^255 - 19 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;

    localparam OP_ADD = 2'd0;
    localparam OP_SUB = 2'd1;
    localparam OP_MUL = 2'd2;

    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_REDUCE  = 2'd2;
    localparam S_DONE    = 2'd3;

    reg [1:0] state;
    reg [1:0] op_reg;

    // Wide intermediates for multiplication
    reg [511:0] product;
    reg [255:0] sum;       // extra bit for carry detection
    reg [255:0] reduced;

    // Reduction: 2^255 ≡ 19 (mod p)
    // For product = lo[254:0] + hi[509:255] * 2^255,
    // reduced = lo + 19 * hi
    wire [254:0] prod_lo  = product[254:0];
    wire [254:0] prod_hi  = product[509:255];
    wire [259:0] mul_reduce_1 = {5'b0, prod_lo} + prod_hi * 19;

    // Second reduction pass (result might still be >= 2^255)
    wire [4:0]   ovf_bits = mul_reduce_1[259:255];
    wire [254:0] low_bits = mul_reduce_1[254:0];
    wire [255:0] mul_reduce_2 = {1'b0, low_bits} + ovf_bits * 19;

    // Final conditional subtraction
    wire [255:0] final_sub = mul_reduce_2 - {1'b0, P};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state   <= S_IDLE;
            result  <= 0;
            done    <= 0;
            product <= 0;
            sum     <= 0;
            reduced <= 0;
            op_reg  <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        op_reg <= op;
                        case (op)
                            OP_ADD: begin
                                sum <= {1'b0, a} + {1'b0, b};
                                state <= S_REDUCE;
                            end
                            OP_SUB: begin
                                // a - b + p to avoid underflow
                                sum <= {1'b0, a} - {1'b0, b} + {1'b0, P};
                                state <= S_REDUCE;
                            end
                            OP_MUL: begin
                                product <= a * b;
                                state <= S_COMPUTE;
                            end
                            default: begin
                                state <= S_IDLE;
                            end
                        endcase
                    end
                end

                S_COMPUTE: begin
                    // Multiplication reduction pass 1:
                    // reduced = prod_lo + 19 * prod_hi
                    // Then pass 2 in REDUCE state
                    sum <= mul_reduce_2;
                    state <= S_REDUCE;
                end

                S_REDUCE: begin
                    // For add/sub: if sum >= p, subtract p
                    // For mul: same check after reduction
                    if (sum >= {1'b0, P})
                        result <= sum[254:0] - P;
                    else
                        result <= sum[254:0];
                    state <= S_DONE;
                end

                S_DONE: begin
                    done <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule // fe25519

//======================================================================
// EOF fe25519.v
//======================================================================
