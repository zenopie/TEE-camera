//======================================================================
//
// fuzzy_extract.v
// ---------------
// Fuzzy extractor using majority vote over multiple PUF measurements.
// Measures the PUF NUM_SAMPLES times and takes majority vote per bit
// to produce stable output.
//
// For simulation (deterministic PUF), all samples are identical,
// so the output equals any single measurement. On real hardware,
// majority vote suppresses noise (~95% per-bit reliability → >99.9%
// with 7 samples).
//
//======================================================================

`default_nettype none

module fuzzy_extract #(
    parameter NUM_BITS    = 128,
    parameter NUM_SAMPLES = 7     // odd number for clean majority
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output reg  [NUM_BITS-1:0]   stable_bits,
    output reg                   done
);

    // PUF instance
    reg                   puf_start;
    wire                  puf_done;
    wire [NUM_BITS-1:0]   puf_raw;

    puf #(.NUM_CELLS(NUM_BITS)) puf_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(puf_start),
        .done(puf_done),
        .raw_bits(puf_raw)
    );

    // Vote counters: count how many times each bit was 1
    // Need enough bits to hold NUM_SAMPLES (ceil(log2(NUM_SAMPLES+1)))
    localparam CNT_W = 4;  // supports up to 15 samples
    reg [CNT_W-1:0] vote [0:NUM_BITS-1];

    // State machine
    localparam S_IDLE    = 3'd0;
    localparam S_CLEAR   = 3'd1;
    localparam S_TRIGGER = 3'd2;
    localparam S_WAIT    = 3'd3;
    localparam S_ACCUM   = 3'd4;
    localparam S_DECIDE  = 3'd5;
    localparam S_DONE    = 3'd6;

    reg [2:0]  state;
    reg [3:0]  sample_cnt;   // which sample we're on (0..NUM_SAMPLES-1)
    reg [7:0]  bit_idx;      // for clearing/deciding loops

    // Threshold for majority: > NUM_SAMPLES/2
    localparam [CNT_W-1:0] THRESHOLD = NUM_SAMPLES / 2;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            done        <= 0;
            stable_bits <= 0;
            puf_start   <= 0;
            sample_cnt  <= 0;
            bit_idx     <= 0;
            for (i = 0; i < NUM_BITS; i = i + 1)
                vote[i] <= 0;
        end else begin
            puf_start <= 0;

            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        sample_cnt <= 0;
                        state      <= S_CLEAR;
                    end
                end

                // Clear all vote counters
                S_CLEAR: begin
                    for (i = 0; i < NUM_BITS; i = i + 1)
                        vote[i] <= 0;
                    state <= S_TRIGGER;
                end

                // Trigger a PUF measurement
                S_TRIGGER: begin
                    puf_start <= 1;
                    state     <= S_WAIT;
                end

                // Wait for PUF measurement to complete
                S_WAIT: begin
                    if (puf_done)
                        state <= S_ACCUM;
                end

                // Accumulate: add each bit to its vote counter
                S_ACCUM: begin
                    for (i = 0; i < NUM_BITS; i = i + 1)
                        vote[i] <= vote[i] + {{(CNT_W-1){1'b0}}, puf_raw[i]};

                    sample_cnt <= sample_cnt + 1;

                    if (sample_cnt == NUM_SAMPLES - 1)
                        state <= S_DECIDE;
                    else
                        state <= S_TRIGGER;
                end

                // Majority decision: bit = 1 if vote > threshold
                S_DECIDE: begin
                    for (i = 0; i < NUM_BITS; i = i + 1)
                        stable_bits[i] <= (vote[i] > THRESHOLD) ? 1'b1 : 1'b0;
                    state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule // fuzzy_extract

//======================================================================
// EOF fuzzy_extract.v
//======================================================================
