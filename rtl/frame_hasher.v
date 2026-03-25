//======================================================================
//
// frame_hasher.v
// --------------
// Streaming SHA-512 frame hasher with hash chaining for batch signing.
//
// SHA-512 instance is EXTERNAL (owned by camera_top and shared with
// the crypto pipeline). This module drives sha_*_req signals and
// reads sha_*_in responses.
//
// Hashes each frame's pixels via SHA-512 on-the-fly (no frame buffer).
// After BATCH_SIZE frames, outputs a chain hash:
//   chain[0] = SHA-512(frame_0_pixels)
//   chain[i] = SHA-512(chain[i-1] || SHA-512(frame_i_pixels))
//
//======================================================================

`default_nettype none

module frame_hasher #(
    parameter BATCH_SIZE = 10
)(
    input  wire          clk,
    input  wire          rst_n,

    // DVP camera interface
    input  wire          vsync,
    input  wire          href,
    input  wire [7:0]    pixel_data,

    // External SHA-512 interface (shared with crypto)
    output reg           sha_init_req,
    output reg           sha_next_req,
    output reg  [1023:0] sha_block_out,
    input  wire          sha_ready_in,
    input  wire [511:0]  sha_digest_in,
    input  wire          sha_valid_in,

    // Status
    output reg           sha_busy,       // 1 = frame_hasher needs SHA-512

    // Hash output (chain hash after BATCH_SIZE frames)
    output reg  [511:0]  frame_hash,
    output reg           hash_valid
);

    //----------------------------------------------------------------
    // Accumulator — 128-byte shift register
    //----------------------------------------------------------------
    reg [1023:0] acc_reg;
    reg [6:0]    acc_count;
    reg [31:0]   total_bytes;
    reg          first_block;

    //----------------------------------------------------------------
    // Batch / chain state
    //----------------------------------------------------------------
    reg [7:0]    frame_in_batch;
    reg [511:0]  chain_hash;
    reg [511:0]  cur_frame_hash;

    //----------------------------------------------------------------
    // VSYNC edge detector
    //----------------------------------------------------------------
    reg vsync_prev;
    wire vsync_rise = vsync && !vsync_prev;
    wire vsync_fall = !vsync && vsync_prev;

    //----------------------------------------------------------------
    // State machine
    //----------------------------------------------------------------
    localparam ST_IDLE        = 4'd0;
    localparam ST_ACTIVE      = 4'd1;
    localparam ST_PAD         = 4'd2;
    localparam ST_PAD_WAIT    = 4'd3;
    localparam ST_FINAL_WAIT  = 4'd4;
    localparam ST_FRAME_DONE  = 4'd5;
    localparam ST_CHAIN_B1    = 4'd6;
    localparam ST_CHAIN_RUN1  = 4'd7;
    localparam ST_CHAIN_DONE1 = 4'd8;
    localparam ST_CHAIN_B2    = 4'd9;
    localparam ST_CHAIN_RUN2  = 4'd10;
    localparam ST_CHAIN_WAIT  = 4'd11;
    localparam ST_BATCH_DONE  = 4'd12;

    reg [3:0] state;

    //----------------------------------------------------------------
    // Padding sub-state
    //----------------------------------------------------------------
    localparam PAD_MARKER = 2'd0;
    localparam PAD_ZEROS  = 2'd1;
    localparam PAD_LENGTH = 2'd2;

    reg [1:0]   pad_phase;
    reg [7:0]   zeros_remaining;
    reg [3:0]   len_remaining;
    reg [127:0] len_shift;

    wire [127:0] msg_len_bits = {93'd0, total_bytes, 3'b000};
    wire [7:0]   remaining = 8'd128 - {1'b0, acc_count};
    wire         pad_fits  = (remaining >= 8'd17);
    wire [7:0]   pad_total = pad_fits ? remaining : (remaining + 8'd128);
    wire [7:0]   zeros_count = pad_total - 8'd17;

    // sha_busy: high whenever frame_hasher is using or needs SHA-512
    always @* begin
        sha_busy = (state != ST_IDLE) && (state != ST_BATCH_DONE);
    end

    //----------------------------------------------------------------
    // Main state machine
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            hash_valid      <= 0;
            frame_hash      <= 0;
            sha_init_req    <= 0;
            sha_next_req    <= 0;
            sha_block_out   <= 0;
            acc_reg         <= 0;
            acc_count       <= 0;
            total_bytes     <= 0;
            first_block     <= 1;
            vsync_prev      <= 0;
            pad_phase       <= PAD_MARKER;
            zeros_remaining <= 0;
            len_remaining   <= 0;
            len_shift       <= 0;
            frame_in_batch  <= 0;
            chain_hash      <= 0;
            cur_frame_hash  <= 0;
        end else begin
            sha_init_req <= 0;
            sha_next_req <= 0;
            hash_valid   <= 0;
            vsync_prev   <= vsync;

            case (state)
                ST_IDLE: begin
                    if (vsync_fall) begin
                        acc_count   <= 0;
                        total_bytes <= 0;
                        first_block <= 1;
                        state       <= ST_ACTIVE;
                    end
                end

                ST_ACTIVE: begin
                    if (href) begin
                        acc_reg     <= {acc_reg[1015:0], pixel_data};
                        total_bytes <= total_bytes + 1;

                        if (acc_count == 7'd127) begin
                            sha_block_out <= {acc_reg[1015:0], pixel_data};
                            sha_init_req  <= first_block;
                            sha_next_req  <= !first_block;
                            first_block   <= 0;
                            acc_count     <= 0;
                        end else begin
                            acc_count <= acc_count + 1;
                        end
                    end

                    if (vsync_rise && !href) begin
                        pad_phase       <= PAD_MARKER;
                        zeros_remaining <= zeros_count;
                        len_remaining   <= 4'd15;
                        len_shift       <= msg_len_bits;
                        state           <= ST_PAD;
                    end
                end

                ST_PAD: begin
                    case (pad_phase)
                        PAD_MARKER: begin
                            acc_reg   <= {acc_reg[1015:0], 8'h80};
                            pad_phase <= (zeros_remaining > 0) ? PAD_ZEROS : PAD_LENGTH;
                        end
                        PAD_ZEROS: begin
                            acc_reg         <= {acc_reg[1015:0], 8'h00};
                            zeros_remaining <= zeros_remaining - 1;
                            if (zeros_remaining == 1)
                                pad_phase <= PAD_LENGTH;
                        end
                        PAD_LENGTH: begin
                            acc_reg       <= {acc_reg[1015:0], len_shift[127:120]};
                            len_shift     <= {len_shift[119:0], 8'd0};
                            len_remaining <= len_remaining - 1;
                        end
                        default: ;
                    endcase

                    if (acc_count == 7'd127) begin
                        case (pad_phase)
                            PAD_MARKER: sha_block_out <= {acc_reg[1015:0], 8'h80};
                            PAD_ZEROS:  sha_block_out <= {acc_reg[1015:0], 8'h00};
                            PAD_LENGTH: sha_block_out <= {acc_reg[1015:0], len_shift[127:120]};
                            default:    sha_block_out <= {acc_reg[1015:0], 8'h00};
                        endcase
                        sha_init_req <= first_block;
                        sha_next_req <= !first_block;
                        first_block  <= 0;
                        acc_count    <= 0;

                        if (pad_phase == PAD_LENGTH && len_remaining == 0)
                            state <= ST_FINAL_WAIT;
                        else
                            state <= ST_PAD_WAIT;
                    end else begin
                        acc_count <= acc_count + 1;
                    end
                end

                ST_PAD_WAIT: begin
                    if (sha_ready_in)
                        state <= ST_PAD;
                end

                ST_FINAL_WAIT: begin
                    if (sha_valid_in) begin
                        cur_frame_hash <= sha_digest_in;
                        state          <= ST_FRAME_DONE;
                    end
                end

                ST_FRAME_DONE: begin
                    if (frame_in_batch == 0) begin
                        chain_hash     <= cur_frame_hash;
                        frame_in_batch <= frame_in_batch + 1;
                        if (BATCH_SIZE == 1) begin
                            frame_hash <= cur_frame_hash;
                            state      <= ST_BATCH_DONE;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        state <= ST_CHAIN_B1;
                    end
                end

                // Chain: SHA-512(chain_hash || cur_frame_hash)
                ST_CHAIN_B1: begin
                    sha_block_out <= {chain_hash, cur_frame_hash};
                    sha_init_req  <= 1;
                    state         <= ST_CHAIN_RUN1;
                end

                ST_CHAIN_RUN1: begin
                    if (!sha_ready_in)
                        state <= ST_CHAIN_DONE1;
                end

                ST_CHAIN_DONE1: begin
                    if (sha_valid_in)
                        state <= ST_CHAIN_B2;
                end

                ST_CHAIN_B2: begin
                    sha_block_out <= {8'h80, {888{1'b0}}, 128'd1024};
                    sha_next_req  <= 1;
                    state         <= ST_CHAIN_RUN2;
                end

                ST_CHAIN_RUN2: begin
                    if (!sha_ready_in)
                        state <= ST_CHAIN_WAIT;
                end

                ST_CHAIN_WAIT: begin
                    if (sha_valid_in) begin
                        chain_hash     <= sha_digest_in;
                        frame_in_batch <= frame_in_batch + 1;
                        if (frame_in_batch + 1 == BATCH_SIZE[7:0]) begin
                            frame_hash <= sha_digest_in;
                            state      <= ST_BATCH_DONE;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_BATCH_DONE: begin
                    hash_valid     <= 1;
                    frame_in_batch <= 0;
                    state          <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
