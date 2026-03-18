//======================================================================
//
// frame_hasher.v
// --------------
// Streaming SHA-512 frame hasher for DVP camera interface.
//
// Accepts pixel bytes as they stream from the camera and computes
// the SHA-512 hash on-the-fly. No frame buffer needed — just a
// 128-byte accumulator feeding the SHA-512 core block by block.
//
// DVP interface:
//   - vsync: high during vertical blanking (between frames)
//   - href:  high during active pixel data
//   - pixel_data: 8-bit pixel byte, valid when href is high
//
// SHA-512 throughput (~38 MBps at 24 MHz) exceeds OV7670 pixel
// rate (24 MBps), so no backpressure or double-buffering is needed.
//
//======================================================================

`default_nettype none

module frame_hasher (
    input  wire          clk,
    input  wire          rst_n,

    // DVP camera interface
    input  wire          vsync,           // high = vertical blanking
    input  wire          href,            // high = valid pixel data
    input  wire [7:0]    pixel_data,      // pixel byte

    // Hash output
    output reg  [511:0]  frame_hash,
    output reg           hash_valid       // pulses high when hash is ready
);

    //----------------------------------------------------------------
    // SHA-512 instance
    //----------------------------------------------------------------
    reg           sha_init, sha_next;
    reg  [1023:0] sha_block;
    wire          sha_ready;
    wire [511:0]  sha_digest;
    wire          sha_valid;

    sha512_core sha_inst (
        .clk(clk),
        .reset_n(rst_n),
        .init(sha_init),
        .next(sha_next),
        .mode(2'd3),          // SHA-512
        .work_factor(1'b0),
        .work_factor_num(32'd0),
        .block(sha_block),
        .ready(sha_ready),
        .digest(sha_digest),
        .digest_valid(sha_valid)
    );

    //----------------------------------------------------------------
    // Accumulator — 128-byte shift register
    //----------------------------------------------------------------
    reg [1023:0] acc_reg;
    reg [6:0]    acc_count;     // 0-127 bytes in accumulator
    reg [31:0]   total_bytes;   // total frame bytes (for padding length)
    reg          first_block;   // 1 = use sha_init, 0 = use sha_next

    //----------------------------------------------------------------
    // VSYNC edge detector
    //----------------------------------------------------------------
    reg vsync_prev;
    wire vsync_rise = vsync && !vsync_prev;
    wire vsync_fall = !vsync && vsync_prev;

    //----------------------------------------------------------------
    // State machine
    //----------------------------------------------------------------
    localparam ST_IDLE       = 3'd0;
    localparam ST_ACTIVE     = 3'd1;  // receiving pixels
    localparam ST_PAD        = 3'd2;  // inserting padding bytes
    localparam ST_PAD_WAIT   = 3'd3;  // wait for SHA block during padding
    localparam ST_FINAL_WAIT = 3'd4;  // wait for final SHA-512 digest
    localparam ST_DONE       = 3'd5;

    reg [2:0] state;

    //----------------------------------------------------------------
    // Padding sub-state
    //----------------------------------------------------------------
    localparam PAD_MARKER = 2'd0;   // insert 0x80
    localparam PAD_ZEROS  = 2'd1;   // insert zero bytes
    localparam PAD_LENGTH = 2'd2;   // insert 16 length bytes

    reg [1:0]   pad_phase;
    reg [7:0]   zeros_remaining;
    reg [3:0]   len_remaining;    // counts down from 15 to 0
    reg [127:0] len_shift;        // shifts out MSB-first

    // Message length in bits (for SHA-512 padding)
    wire [127:0] msg_len_bits = {93'd0, total_bytes, 3'b000};

    //----------------------------------------------------------------
    // Shared: feed a byte into the accumulator and process full blocks
    //----------------------------------------------------------------
    reg        feed_byte_en;
    reg  [7:0] feed_byte;
    reg        block_just_processed;

    // Compute padding size
    wire [7:0] remaining = 8'd128 - {1'b0, acc_count};
    wire       pad_fits  = (remaining >= 8'd17);
    wire [7:0] pad_total = pad_fits ? remaining : (remaining + 8'd128);
    wire [7:0] zeros_count = pad_total - 8'd17;

    //----------------------------------------------------------------
    // Main state machine
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            hash_valid      <= 0;
            frame_hash      <= 0;
            sha_init        <= 0;
            sha_next        <= 0;
            sha_block       <= 0;
            acc_reg         <= 0;
            acc_count       <= 0;
            total_bytes     <= 0;
            first_block     <= 1;
            vsync_prev      <= 1;  // assume blanking at start
            pad_phase       <= PAD_MARKER;
            zeros_remaining <= 0;
            len_remaining   <= 0;
            len_shift       <= 0;
            block_just_processed <= 0;
        end else begin
            // Defaults
            sha_init   <= 0;
            sha_next   <= 0;
            hash_valid <= 0;
            vsync_prev <= vsync;
            block_just_processed <= 0;

            case (state)
                // ── Wait for frame start ──
                ST_IDLE: begin
                    if (vsync_fall) begin
                        acc_count   <= 0;
                        total_bytes <= 0;
                        first_block <= 1;
                        state       <= ST_ACTIVE;
                    end
                end

                // ── Receive pixels, hash on the fly ──
                ST_ACTIVE: begin
                    if (href) begin
                        // Shift pixel byte in (MSB-first for SHA-512)
                        acc_reg     <= {acc_reg[1015:0], pixel_data};
                        total_bytes <= total_bytes + 1;

                        if (acc_count == 7'd127) begin
                            // Block complete — feed to SHA-512
                            // SHA-512 must be ready (82 cycles < 128 pixel cycles)
                            `ifdef SIMULATION
                            if (!sha_ready)
                                $display("ERROR: SHA-512 not ready for new block at t=%0t", $time);
                            `endif
                            sha_block  <= {acc_reg[1015:0], pixel_data};
                            sha_init   <= first_block;
                            sha_next   <= !first_block;
                            first_block <= 0;
                            acc_count  <= 0;
                        end else begin
                            acc_count <= acc_count + 1;
                        end
                    end

                    // Frame end — start padding
                    if (vsync_rise && !href) begin
                        pad_phase       <= PAD_MARKER;
                        zeros_remaining <= zeros_count;
                        len_remaining   <= 4'd15;
                        len_shift       <= msg_len_bits;
                        state           <= ST_PAD;
                    end
                end

                // ── Insert padding bytes ──
                ST_PAD: begin
                    // Determine padding byte
                    case (pad_phase)
                        PAD_MARKER: begin
                            // Shift in 0x80
                            acc_reg   <= {acc_reg[1015:0], 8'h80};
                            pad_phase <= (zeros_remaining > 0) ? PAD_ZEROS : PAD_LENGTH;
                        end

                        PAD_ZEROS: begin
                            // Shift in 0x00
                            acc_reg         <= {acc_reg[1015:0], 8'h00};
                            zeros_remaining <= zeros_remaining - 1;
                            if (zeros_remaining == 1)
                                pad_phase <= PAD_LENGTH;
                        end

                        PAD_LENGTH: begin
                            // Shift in length byte (MSB first)
                            acc_reg       <= {acc_reg[1015:0], len_shift[127:120]};
                            len_shift     <= {len_shift[119:0], 8'd0};
                            len_remaining <= len_remaining - 1;
                        end

                        default: ;
                    endcase

                    // Check if block is complete
                    if (acc_count == 7'd127) begin
                        // Block complete
                        case (pad_phase)
                            PAD_MARKER: sha_block <= {acc_reg[1015:0], 8'h80};
                            PAD_ZEROS:  sha_block <= {acc_reg[1015:0], 8'h00};
                            PAD_LENGTH: sha_block <= {acc_reg[1015:0], len_shift[127:120]};
                            default:    sha_block <= {acc_reg[1015:0], 8'h00};
                        endcase
                        sha_init    <= first_block;
                        sha_next    <= !first_block;
                        first_block <= 0;
                        acc_count   <= 0;
                        block_just_processed <= 1;

                        // If this was the last length byte, we're done padding
                        if (pad_phase == PAD_LENGTH && len_remaining == 0)
                            state <= ST_FINAL_WAIT;
                        else
                            state <= ST_PAD_WAIT;
                    end else begin
                        acc_count <= acc_count + 1;
                        // If last length byte but block not full — shouldn't happen
                        // (padding is designed so last byte fills a block)
                    end
                end

                // ── Wait for SHA-512 between padding blocks ──
                ST_PAD_WAIT: begin
                    if (sha_ready)
                        state <= ST_PAD;
                end

                // ── Wait for final digest ──
                ST_FINAL_WAIT: begin
                    if (sha_valid) begin
                        frame_hash <= sha_digest;
                        state      <= ST_DONE;
                    end
                end

                // ── Output hash ──
                ST_DONE: begin
                    hash_valid <= 1;
                    state      <= ST_IDLE;
                end
            endcase
        end
    end

endmodule // frame_hasher

//======================================================================
// EOF frame_hasher.v
//======================================================================
