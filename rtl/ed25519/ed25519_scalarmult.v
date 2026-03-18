//======================================================================
//
// ed25519_scalarmult.v
// --------------------
// Scalar multiplication [k]P on Ed25519 using double-and-add.
// Wraps ed25519_point for point operations.
//
// Algorithm (left-to-right binary):
//   Q = identity
//   for i from 254 down to 0:
//       Q = 2*Q
//       if bit i of scalar is 1:
//           Q = Q + P
//   return Q
//
// Identity point in extended coords: (0, 1, 1, 0)
//
//======================================================================

`default_nettype none

module ed25519_scalarmult (
    input  wire         clk,
    input  wire         reset_n,

    // Scalar (255 bits, already clamped for Ed25519)
    input  wire [254:0] scalar,

    // Base point P
    input  wire [254:0] p_x, p_y, p_z, p_t,

    // Control
    input  wire         start,

    // Result: [scalar]P
    output wire [254:0] q_x, q_y, q_z, q_t,
    output reg          done
);

    //----------------------------------------------------------------
    // State machine
    //----------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_LOAD      = 3'd1;
    localparam S_DBL_START = 3'd2;
    localparam S_DBL_WAIT  = 3'd3;
    localparam S_ADD_START = 3'd4;
    localparam S_ADD_WAIT  = 3'd5;
    localparam S_NEXT_BIT  = 3'd6;
    localparam S_DONE      = 3'd7;

    reg [2:0]  state;
    reg [8:0]  bit_idx;    // current bit being processed (254 down to 0)
    reg [254:0] scalar_reg;

    //----------------------------------------------------------------
    // Point operations unit
    //----------------------------------------------------------------
    reg [254:0] pt_q_x, pt_q_y, pt_q_z, pt_q_t;
    reg         pt_q_load;
    reg [254:0] pt_b_x, pt_b_y, pt_b_z, pt_b_t;
    reg         pt_b_load;
    reg         pt_start_dbl, pt_start_add;
    wire        pt_done;

    ed25519_point point_ops (
        .clk(clk),
        .reset_n(reset_n),
        .q_x_in(pt_q_x), .q_y_in(pt_q_y),
        .q_z_in(pt_q_z), .q_t_in(pt_q_t),
        .q_load(pt_q_load),
        .b_x_in(pt_b_x), .b_y_in(pt_b_y),
        .b_z_in(pt_b_z), .b_t_in(pt_b_t),
        .b_load(pt_b_load),
        .start_dbl(pt_start_dbl),
        .start_add(pt_start_add),
        .q_x(q_x), .q_y(q_y), .q_z(q_z), .q_t(q_t),
        .done(pt_done)
    );

    //----------------------------------------------------------------
    // Main control
    //----------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= S_IDLE;
            done          <= 0;
            bit_idx       <= 0;
            scalar_reg    <= 0;
            pt_q_load     <= 0;
            pt_b_load     <= 0;
            pt_start_dbl  <= 0;
            pt_start_add  <= 0;
            pt_q_x <= 0; pt_q_y <= 0; pt_q_z <= 0; pt_q_t <= 0;
            pt_b_x <= 0; pt_b_y <= 0; pt_b_z <= 0; pt_b_t <= 0;
        end else begin
            // Default: deassert one-shot signals
            pt_q_load    <= 0;
            pt_b_load    <= 0;
            pt_start_dbl <= 0;
            pt_start_add <= 0;

            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        scalar_reg <= scalar;
                        state      <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    // Load identity (0, 1, 1, 0) as Q
                    pt_q_x <= 255'd0;
                    pt_q_y <= 255'd1;
                    pt_q_z <= 255'd1;
                    pt_q_t <= 255'd0;
                    pt_q_load <= 1;
                    // Load base point P as B
                    pt_b_x <= p_x;
                    pt_b_y <= p_y;
                    pt_b_z <= p_z;
                    pt_b_t <= p_t;
                    pt_b_load <= 1;
                    // Start from bit 254
                    bit_idx <= 9'd254;
                    state   <= S_DBL_START;
                end

                S_DBL_START: begin
                    // Q = 2*Q
                    pt_start_dbl <= 1;
                    state        <= S_DBL_WAIT;
                end

                S_DBL_WAIT: begin
                    if (pt_done) begin
                        // Check if current bit is set
                        if (scalar_reg[bit_idx[7:0]]) begin
                            state <= S_ADD_START;
                        end else begin
                            state <= S_NEXT_BIT;
                        end
                    end
                end

                S_ADD_START: begin
                    // Q = Q + B
                    pt_start_add <= 1;
                    state        <= S_ADD_WAIT;
                end

                S_ADD_WAIT: begin
                    if (pt_done) begin
                        state <= S_NEXT_BIT;
                    end
                end

                S_NEXT_BIT: begin
                    if (bit_idx == 0) begin
                        state <= S_DONE;
                    end else begin
                        bit_idx <= bit_idx - 1;
                        state   <= S_DBL_START;
                    end
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule // ed25519_scalarmult

//======================================================================
// EOF ed25519_scalarmult.v
//======================================================================
