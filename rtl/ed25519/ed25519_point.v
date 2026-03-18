//======================================================================
//
// ed25519_point.v
// ---------------
// Point addition and doubling on Ed25519 (twisted Edwards, a=-1).
// Uses extended coordinates (X, Y, Z, T) where x=X/Z, y=Y/Z, T=XY/Z.
//
// Formulas from hyperelliptic.org/EFD:
//   Addition: add-2008-hwcd-4 (8M + 8add, no multiply by d)
//   Doubling: dbl-2008-hwcd   (4M + 4S + 6add, a=-1 simplified)
//
// Architecture: register file + single fe25519 ALU + microcode sequencer.
// The ALU is time-shared across all field operations.
//
// Interface for scalar multiplication:
//   - Load working point Q and base point B
//   - start_dbl: Q = 2*Q
//   - start_add: Q = Q + B
//   - Read result from q_x/y/z/t outputs
//
//======================================================================

`default_nettype none

module ed25519_point (
    input  wire         clk,
    input  wire         reset_n,

    // Load working point Q
    input  wire [254:0] q_x_in, q_y_in, q_z_in, q_t_in,
    input  wire         q_load,

    // Load base point B
    input  wire [254:0] b_x_in, b_y_in, b_z_in, b_t_in,
    input  wire         b_load,

    // Operations
    input  wire         start_dbl,  // Q = 2*Q
    input  wire         start_add,  // Q = Q + B

    // Current Q (always valid)
    output wire [254:0] q_x, q_y, q_z, q_t,
    output reg          done
);

    // p = 2^255 - 19
    localparam [254:0] P = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed;

    // ALU opcodes (match fe25519)
    localparam OP_ADD = 2'd0;
    localparam OP_SUB = 2'd1;
    localparam OP_MUL = 2'd2;

    //----------------------------------------------------------------
    // Register file: 16 x 255-bit field elements
    //   [0..3] = Q: Qx, Qy, Qz, Qt
    //   [4..7] = B: Bx, By, Bz, Bt
    //   [8..15] = temporaries (A, B_t, C, D, E, F, G, H)
    //----------------------------------------------------------------
    reg [254:0] rf [0:15];

    assign q_x = rf[0];
    assign q_y = rf[1];
    assign q_z = rf[2];
    assign q_t = rf[3];

    //----------------------------------------------------------------
    // fe25519 ALU instance
    //----------------------------------------------------------------
    reg  [1:0]   alu_op;
    reg  [254:0] alu_a, alu_b;
    reg          alu_start;
    wire [254:0] alu_result;
    wire         alu_done;

    fe25519 alu (
        .clk(clk),
        .reset_n(reset_n),
        .op(alu_op),
        .a(alu_a),
        .b(alu_b),
        .start(alu_start),
        .result(alu_result),
        .done(alu_done)
    );

    //----------------------------------------------------------------
    // State machine
    //----------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_EXEC    = 2'd1;  // ALU running
    localparam S_STORE   = 2'd2;  // store result, advance step
    localparam S_DONE    = 2'd3;

    reg [1:0] state;
    reg [4:0] step;
    reg       is_add;     // 1=addition, 0=doubling
    reg [3:0] dst_idx;    // where to store ALU result

    // Number of steps for each operation
    wire [4:0] max_step = is_add ? 5'd17 : 5'd15;

    //----------------------------------------------------------------
    // Microcode decode: for each step, determine ALU op, operands, dest
    //----------------------------------------------------------------
    reg [1:0]   mc_op;
    reg [254:0] mc_a, mc_b;
    reg [3:0]   mc_dst;

    always @* begin
        mc_op  = OP_ADD;
        mc_a   = 0;
        mc_b   = 0;
        mc_dst = 0;

        if (is_add) begin
            // Point addition: Q = Q + B  (add-2008-hwcd-4)
            case (step)
                // A = (Qy - Qx) * (By + Bx)
                0:  begin mc_op=OP_SUB; mc_a=rf[1]; mc_b=rf[0]; mc_dst=4'd8;  end // t0 = Qy-Qx
                1:  begin mc_op=OP_ADD; mc_a=rf[5]; mc_b=rf[4]; mc_dst=4'd9;  end // t1 = By+Bx
                2:  begin mc_op=OP_MUL; mc_a=rf[8]; mc_b=rf[9]; mc_dst=4'd8;  end // A = t0*t1
                // B = (Qy + Qx) * (By - Bx)
                3:  begin mc_op=OP_ADD; mc_a=rf[1]; mc_b=rf[0]; mc_dst=4'd9;  end // t2 = Qy+Qx
                4:  begin mc_op=OP_SUB; mc_a=rf[5]; mc_b=rf[4]; mc_dst=4'd10; end // t3 = By-Bx
                5:  begin mc_op=OP_MUL; mc_a=rf[9]; mc_b=rf[10];mc_dst=4'd9;  end // B = t2*t3
                // C = 2 * Qz * Bt
                6:  begin mc_op=OP_MUL; mc_a=rf[2]; mc_b=rf[7]; mc_dst=4'd10; end // C'= Qz*Bt
                7:  begin mc_op=OP_ADD; mc_a=rf[10];mc_b=rf[10];mc_dst=4'd10; end // C = 2*C'
                // D = 2 * Qt * Bz
                8:  begin mc_op=OP_MUL; mc_a=rf[3]; mc_b=rf[6]; mc_dst=4'd11; end // D'= Qt*Bz
                9:  begin mc_op=OP_ADD; mc_a=rf[11];mc_b=rf[11];mc_dst=4'd11; end // D = 2*D'
                // E, F, G, H
                10: begin mc_op=OP_ADD; mc_a=rf[11];mc_b=rf[10];mc_dst=4'd12; end // E = D+C
                11: begin mc_op=OP_SUB; mc_a=rf[9]; mc_b=rf[8]; mc_dst=4'd13; end // F = B-A
                12: begin mc_op=OP_ADD; mc_a=rf[9]; mc_b=rf[8]; mc_dst=4'd14; end // G = B+A
                13: begin mc_op=OP_SUB; mc_a=rf[11];mc_b=rf[10];mc_dst=4'd15; end // H = D-C
                // Result → Q
                14: begin mc_op=OP_MUL; mc_a=rf[12];mc_b=rf[13];mc_dst=4'd0;  end // Qx = E*F
                15: begin mc_op=OP_MUL; mc_a=rf[14];mc_b=rf[15];mc_dst=4'd1;  end // Qy = G*H
                16: begin mc_op=OP_MUL; mc_a=rf[12];mc_b=rf[15];mc_dst=4'd3;  end // Qt = E*H
                17: begin mc_op=OP_MUL; mc_a=rf[13];mc_b=rf[14];mc_dst=4'd2;  end // Qz = F*G
                default: ;
            endcase
        end else begin
            // Point doubling: Q = 2*Q  (dbl-2008-hwcd, a=-1)
            case (step)
                // A = Qx^2, B = Qy^2, C = 2*Qz^2
                0:  begin mc_op=OP_MUL; mc_a=rf[0]; mc_b=rf[0]; mc_dst=4'd8;  end // A = Qx^2
                1:  begin mc_op=OP_MUL; mc_a=rf[1]; mc_b=rf[1]; mc_dst=4'd9;  end // B = Qy^2
                2:  begin mc_op=OP_MUL; mc_a=rf[2]; mc_b=rf[2]; mc_dst=4'd10; end // C'= Qz^2
                3:  begin mc_op=OP_ADD; mc_a=rf[10];mc_b=rf[10];mc_dst=4'd10; end // C = 2*C'
                // E = (Qx+Qy)^2 - A - B
                4:  begin mc_op=OP_ADD; mc_a=rf[0]; mc_b=rf[1]; mc_dst=4'd11; end // t = Qx+Qy
                5:  begin mc_op=OP_MUL; mc_a=rf[11];mc_b=rf[11];mc_dst=4'd11; end // t = t^2
                6:  begin mc_op=OP_SUB; mc_a=rf[11];mc_b=rf[8]; mc_dst=4'd11; end // t = t-A
                7:  begin mc_op=OP_SUB; mc_a=rf[11];mc_b=rf[9]; mc_dst=4'd12; end // E = t-B
                // G = B - A, F = G - C
                8:  begin mc_op=OP_SUB; mc_a=rf[9]; mc_b=rf[8]; mc_dst=4'd14; end // G = B-A
                9:  begin mc_op=OP_SUB; mc_a=rf[14];mc_b=rf[10];mc_dst=4'd13; end // F = G-C
                // H = -(A+B) = 0 - (A+B) mod p
                10: begin mc_op=OP_ADD; mc_a=rf[8]; mc_b=rf[9]; mc_dst=4'd15; end // t = A+B
                11: begin mc_op=OP_SUB; mc_a=255'd0;mc_b=rf[15];mc_dst=4'd15; end // H = -t
                // Result → Q
                12: begin mc_op=OP_MUL; mc_a=rf[12];mc_b=rf[13];mc_dst=4'd0;  end // Qx = E*F
                13: begin mc_op=OP_MUL; mc_a=rf[14];mc_b=rf[15];mc_dst=4'd1;  end // Qy = G*H
                14: begin mc_op=OP_MUL; mc_a=rf[12];mc_b=rf[15];mc_dst=4'd3;  end // Qt = E*H
                15: begin mc_op=OP_MUL; mc_a=rf[13];mc_b=rf[14];mc_dst=4'd2;  end // Qz = F*G
                default: ;
            endcase
        end
    end

    //----------------------------------------------------------------
    // Main state machine
    //----------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= S_IDLE;
            step      <= 0;
            done      <= 0;
            is_add    <= 0;
            dst_idx   <= 0;
            alu_start <= 0;
            alu_op    <= 0;
            alu_a     <= 0;
            alu_b     <= 0;
            for (i = 0; i < 16; i = i + 1)
                rf[i] <= 0;
        end else begin
            alu_start <= 0;

            // Register load operations (always available)
            if (q_load) begin
                rf[0] <= q_x_in;
                rf[1] <= q_y_in;
                rf[2] <= q_z_in;
                rf[3] <= q_t_in;
            end
            if (b_load) begin
                rf[4] <= b_x_in;
                rf[5] <= b_y_in;
                rf[6] <= b_z_in;
                rf[7] <= b_t_in;
            end

            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start_add || start_dbl) begin
                        is_add <= start_add;
                        step   <= 0;
                        state  <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    // Launch ALU with current step's microcode
                    alu_op    <= mc_op;
                    alu_a     <= mc_a;
                    alu_b     <= mc_b;
                    dst_idx   <= mc_dst;
                    alu_start <= 1;
                    state     <= S_STORE;
                end

                S_STORE: begin
                    if (alu_done) begin
                        // Store result
                        rf[dst_idx] <= alu_result;

                        if (step == max_step) begin
                            state <= S_DONE;
                        end else begin
                            step  <= step + 1;
                            state <= S_EXEC;
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule // ed25519_point

//======================================================================
// EOF ed25519_point.v
//======================================================================
