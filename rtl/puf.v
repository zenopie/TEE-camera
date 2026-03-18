// puf.v — Ring Oscillator PUF for iCE40UP5K
//
// Based on stnolting/fpga_puf approach: single-inverter cells with
// sequential measurement via shift register.
//
// Each PUF cell is one LUT configured as an inverter feeding back on
// itself. A latch opens for one clock cycle, letting the inverter
// oscillate, then captures the state (0 or 1). Manufacturing variations
// determine which state each cell settles to.
//
// For simulation, the cells produce deterministic values derived from
// their index (real hardware would have true randomness from silicon).
//
// Parameters:
//   NUM_CELLS - number of PUF cells (each produces 1 raw bit)

module puf #(
    parameter NUM_CELLS = 128
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,          // pulse to begin measurement
    output reg  done,           // high when measurement complete
    output reg  [NUM_CELLS-1:0] raw_bits  // raw PUF response
);

    // State machine
    localparam IDLE    = 2'd0;
    localparam MEASURE = 2'd1;
    localparam LATCH   = 2'd2;
    localparam DONE_ST = 2'd3;

    reg [1:0] state;
    reg [$clog2(NUM_CELLS)-1:0] cell_idx;
    reg [7:0] osc_counter;  // count oscillation cycles

    // Oscillation settle time (clock cycles to let RO stabilize)
    localparam SETTLE_CYCLES = 8'd16;

    // --- PUF cell array ---
    // In real hardware: each cell is an SB_LUT4 configured as inverter
    // with feedback. For simulation, we model the settled state.

    // Simulated PUF cell output (deterministic for simulation)
    // In real silicon this comes from manufacturing variations
    wire cell_out;

    `ifdef SIMULATION
        // Simulation: deterministic "fingerprint" based on cell index
        // XOR with a pattern to simulate unique-per-device behavior
        assign cell_out = (cell_idx[0] ^ cell_idx[2] ^ cell_idx[4] ^ cell_idx[6]);
    `else
        // Real hardware: ring oscillator cell
        // The SB_LUT4 instantiation prevents Yosys from optimizing it away
        (* keep *)
        wire ro_chain;

        SB_LUT4 #(
            .LUT_INIT(16'b0101_0101_0101_0101) // NOT gate
        ) ro_lut (
            .I0(ro_chain),
            .I1(1'b0),
            .I2(1'b0),
            .I3(1'b0),
            .O(ro_chain)
        );

        // Latch the oscillator state
        reg cell_latch;
        always @(posedge clk) begin
            if (state == LATCH)
                cell_latch <= ro_chain;
        end
        assign cell_out = cell_latch;
    `endif

    // --- State machine ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            cell_idx  <= 0;
            osc_counter <= 0;
            done      <= 0;
            raw_bits  <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        cell_idx    <= 0;
                        osc_counter <= 0;
                        state       <= MEASURE;
                    end
                end

                MEASURE: begin
                    // Let oscillator run for SETTLE_CYCLES
                    if (osc_counter < SETTLE_CYCLES) begin
                        osc_counter <= osc_counter + 1;
                    end else begin
                        state <= LATCH;
                    end
                end

                LATCH: begin
                    // Capture this cell's bit
                    raw_bits[cell_idx] <= cell_out;

                    if (cell_idx == NUM_CELLS - 1) begin
                        state <= DONE_ST;
                    end else begin
                        cell_idx    <= cell_idx + 1;
                        osc_counter <= 0;
                        state       <= MEASURE;
                    end
                end

                DONE_ST: begin
                    done  <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
