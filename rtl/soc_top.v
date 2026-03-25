//======================================================================
// soc_top.v — RISC-V SoC for camera attestation
//
// PicoRV32 core + EBR code/data + hardware peripherals.
// CPU handles Ed25519 signing in C. Hardware handles SHA-512 + PUF.
//
// Memory map:
//   0x0000_0000 - 0x0000_7FFF  Code ROM (32 KB, EBR)
//   0x0000_8000 - 0x0000_9FFF  Data RAM (8 KB, EBR)
//   0x8000_0000 - 0x8000_00FF  Hardware registers:
//     0x00: [R]  status    (bit 0: puf_done, bit 1: hash_valid, bit 2: signing_busy)
//     0x04: [W]  control   (bit 0: start_boot_hash, bit 1: ack_hash)
//     0x08: [R]  puf_bits[31:0]
//     0x0C: [R]  puf_bits[63:0]  (upper)
//     0x10: [R]  puf_bits[95:64]
//     0x14: [R]  puf_bits[127:96]
//     0x20-0x5C: [R]  frame_hash[511:0] (16 × 32-bit words)
//     0x60-0x7C: [W]  uart_tx_data (write byte to 0x60, busy at 0x64)
//     0x80-0xBF: [W]  signature output (64 bytes, written by CPU)
//     0xC0: [W]  send_sig  (trigger UART send of signature)
//     0xC4: [W]  send_pk   (trigger UART send of public key)
//     0xC8-0xE7: [W]  pubkey (32 bytes)
//======================================================================

`default_nettype none

module soc_top #(
    parameter CLK_FREQ   = 24_000_000,
    parameter BAUD_RATE  = 115_200,
    parameter BATCH_SIZE = 250
)(
    input  wire       clk,
    input  wire       rst_n,

    // Camera DVP
    input  wire       vsync,
    input  wire       href,
    input  wire [7:0] pixel_data,

    // UART
    output wire       uart_txd,
    input  wire       uart_rxd,

    // Status
    output wire       boot_done,
    output wire       signing,

    // Signature data readback (for HDMI barcode renderer)
    input  wire [7:0] sig_rd_addr,
    output wire [7:0] sig_rd_data
);

    // Reset is active-low external, active-high for PicoRV32
    wire reset = !rst_n;

    //================================================================
    // PicoRV32 core
    //================================================================
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;

    picorv32 #(
        .ENABLE_COUNTERS(0),
        .ENABLE_COUNTERS64(0),
        .ENABLE_MUL(1),        // hardware multiply for Ed25519
        .ENABLE_DIV(0),
        .ENABLE_IRQ(0),
        .ENABLE_TRACE(0),
        .BARREL_SHIFTER(1),
        .COMPRESSED_ISA(0),
        .STACKADDR(32'h0000_9FFC)  // top of data RAM
    ) cpu (
        .clk(clk),
        .resetn(rst_n),
        .mem_valid(mem_valid),
        .mem_instr(mem_instr),
        .mem_ready(mem_ready),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        // Unused
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0),
        .eoi(),
        .trace_valid(),
        .trace_data()
    );

    //================================================================
    // Address decode
    //================================================================
    wire sel_rom  = mem_valid && (mem_addr[31:15] == 17'd0);      // 0x0000-0x7FFF
    wire sel_ram  = mem_valid && (mem_addr[31:13] == 19'b0000000000000000100); // 0x8000-0x9FFF
    wire sel_io   = mem_valid && (mem_addr[31]   == 1'b1);        // 0x8000_0000+

    reg        rom_ready, ram_ready, io_ready;
    reg [31:0] rom_rdata, ram_rdata, io_rdata;

    assign mem_ready = rom_ready | ram_ready | io_ready;
    assign mem_rdata = sel_rom ? rom_rdata :
                       sel_ram ? ram_rdata :
                       io_rdata;

    //================================================================
    // Code ROM (20 KB = 5120 × 32-bit, 10 EBR blocks)
    //================================================================
    reg [31:0] code_rom [0:5119];
    initial $readmemh("firmware.hex", code_rom);

    always @(posedge clk) begin
        rom_ready <= 0;
        if (sel_rom && !rom_ready) begin
            rom_rdata <= code_rom[mem_addr[14:2]];
            rom_ready <= 1;
        end
    end

    //================================================================
    // Data RAM (8 KB = 2048 × 32-bit, 4 EBR blocks)
    //================================================================
    reg [31:0] data_ram [0:2047];

    always @(posedge clk) begin
        ram_ready <= 0;
        if (sel_ram && !ram_ready) begin
            ram_rdata <= data_ram[mem_addr[12:2]];
            if (mem_wstrb[0]) data_ram[mem_addr[12:2]][ 7: 0] <= mem_wdata[ 7: 0];
            if (mem_wstrb[1]) data_ram[mem_addr[12:2]][15: 8] <= mem_wdata[15: 8];
            if (mem_wstrb[2]) data_ram[mem_addr[12:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) data_ram[mem_addr[12:2]][31:24] <= mem_wdata[31:24];
            ram_ready <= 1;
        end
    end

    //================================================================
    // PUF + Fuzzy Extractor
    //================================================================
    reg          puf_start;
    wire [127:0] puf_bits;

    wire puf_done_pulse;
    fuzzy_extract #(.NUM_BITS(128), .NUM_SAMPLES(7)) fe_inst (
        .clk(clk), .rst_n(rst_n),
        .start(puf_start), .stable_bits(puf_bits), .done(puf_done_pulse)
    );

    // Latch puf_done — the fuzzy_extract done signal is a single-cycle pulse,
    // but firmware polls it, so it must stay high once asserted.
    reg puf_done_latch;
    always @(posedge clk) begin
        if (reset)
            puf_done_latch <= 0;
        else if (puf_done_pulse)
            puf_done_latch <= 1;
    end
    wire puf_done = puf_done_latch;

    // Auto-start PUF on boot
    reg puf_started;
    always @(posedge clk) begin
        if (reset) begin
            puf_start   <= 0;
            puf_started <= 0;
        end else if (!puf_started) begin
            puf_start   <= 1;
            puf_started <= 1;
        end else
            puf_start <= 0;
    end

    //================================================================
    // SHA-512 (shared between frame_hasher and CPU)
    //================================================================
    reg          cpu_sha_init, cpu_sha_next;
    reg  [1023:0] cpu_sha_block;
    wire         fh_sha_init_req, fh_sha_next_req;
    wire [1023:0] fh_sha_block_out;
    wire         fh_sha_busy;

    wire sha_init  = fh_sha_busy ? fh_sha_init_req : cpu_sha_init;
    wire sha_next  = fh_sha_busy ? fh_sha_next_req : cpu_sha_next;
    wire [1023:0] sha_block = fh_sha_busy ? fh_sha_block_out : cpu_sha_block;
    wire         sha_ready, sha_valid;
    wire [511:0] sha_digest;

    sha512_core sha_inst (
        .clk(clk), .reset_n(rst_n),
        .init(sha_init), .next(sha_next),
        .mode(2'd3), .work_factor(1'b0), .work_factor_num(32'd0),
        .block(sha_block),
        .ready(sha_ready), .digest(sha_digest), .digest_valid(sha_valid)
    );

    //================================================================
    // Frame Hasher
    //================================================================
    wire [511:0] fh_hash;
    wire         fh_valid;

    frame_hasher #(.BATCH_SIZE(BATCH_SIZE)) hasher_inst (
        .clk(clk), .rst_n(rst_n),
        .vsync(vsync), .href(href), .pixel_data(pixel_data),
        .sha_init_req(fh_sha_init_req), .sha_next_req(fh_sha_next_req),
        .sha_block_out(fh_sha_block_out),
        .sha_ready_in(sha_ready), .sha_digest_in(sha_digest),
        .sha_valid_in(sha_valid),
        .sha_busy(fh_sha_busy),
        .frame_hash(fh_hash), .hash_valid(fh_valid)
    );

    //================================================================
    // UART TX
    //================================================================
    reg  [7:0] tx_byte;
    reg        tx_send;
    wire       tx_busy;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) tx_inst (
        .clk(clk), .rst_n(rst_n),
        .data(tx_byte), .send(tx_send),
        .tx(uart_txd), .busy(tx_busy)
    );

    //================================================================
    // Hash valid latch (sticky until CPU acks)
    //================================================================
    reg hash_valid_latch;
    reg [511:0] frame_hash_reg;
    reg [31:0]  frame_count;
    reg         ack_hash;
    reg         signing_reg;

    assign boot_done = puf_done;
    assign signing   = signing_reg;

    //================================================================
    // Signature data register file (164 bytes)
    // Written by CPU, read by HDMI barcode renderer.
    // Layout: pubkey(32) + frame_num(4) + hash(64) + sig(64)
    //================================================================
    reg [7:0] sig_data [0:163];
    assign sig_rd_data = sig_data[sig_rd_addr];

    always @(posedge clk) begin
        if (reset) begin
            hash_valid_latch <= 0;
            frame_hash_reg   <= 0;
            frame_count      <= 1;
        end else begin
            if (fh_valid) begin
                hash_valid_latch <= 1;
                frame_hash_reg   <= fh_hash;
                frame_count      <= frame_count + 1;
            end
            if (ack_hash)
                hash_valid_latch <= 0;
        end
    end

    //================================================================
    // IO Register interface
    //================================================================
    always @(posedge clk) begin
        io_ready    <= 0;
        tx_send     <= 0;
        ack_hash    <= 0;
        cpu_sha_init <= 0;
        cpu_sha_next <= 0;

        if (sel_io && !io_ready) begin
            io_ready <= 1;

            case (mem_addr[7:0])
                // Status register
                8'h00: io_rdata <= {29'd0, signing_reg, hash_valid_latch, puf_done};

                // Control register (write)
                8'h04: begin
                    if (mem_wstrb[0]) begin
                        if (mem_wdata[1]) ack_hash <= 1;
                        if (mem_wdata[2]) signing_reg <= 1;
                        if (mem_wdata[3]) signing_reg <= 0;
                    end
                end

                // PUF bits (read, 4 × 32-bit)
                8'h08: io_rdata <= puf_bits[ 31:  0];
                8'h0C: io_rdata <= puf_bits[ 63: 32];
                8'h10: io_rdata <= puf_bits[ 95: 64];
                8'h14: io_rdata <= puf_bits[127: 96];

                // Frame hash (read, 16 × 32-bit)
                8'h20: io_rdata <= frame_hash_reg[ 31:  0];
                8'h24: io_rdata <= frame_hash_reg[ 63: 32];
                8'h28: io_rdata <= frame_hash_reg[ 95: 64];
                8'h2C: io_rdata <= frame_hash_reg[127: 96];
                8'h30: io_rdata <= frame_hash_reg[159:128];
                8'h34: io_rdata <= frame_hash_reg[191:160];
                8'h38: io_rdata <= frame_hash_reg[223:192];
                8'h3C: io_rdata <= frame_hash_reg[255:224];
                8'h40: io_rdata <= frame_hash_reg[287:256];
                8'h44: io_rdata <= frame_hash_reg[319:288];
                8'h48: io_rdata <= frame_hash_reg[351:320];
                8'h4C: io_rdata <= frame_hash_reg[383:352];
                8'h50: io_rdata <= frame_hash_reg[415:384];
                8'h54: io_rdata <= frame_hash_reg[447:416];
                8'h58: io_rdata <= frame_hash_reg[479:448];
                8'h5C: io_rdata <= frame_hash_reg[511:480];

                // UART TX (write byte to 0x60, read busy from 0x64)
                8'h60: begin
                    if (mem_wstrb[0]) begin
                        tx_byte <= mem_wdata[7:0];
                        tx_send <= 1;
                    end
                end
                8'h64: io_rdata <= {31'd0, tx_busy};

                // Frame count
                8'h68: io_rdata <= frame_count;

                default: io_rdata <= 32'hDEADBEEF;
            endcase

            // Signature data register file: addresses 0x80-0x123
            // Written as 32-bit words, byte-enables via mem_wstrb
            if (mem_addr[8:0] >= 9'h080 && mem_addr[8:0] < 9'h124 && (|mem_wstrb)) begin
                // Byte offset = (address - 0x80), word-aligned
                // Each word write stores 4 bytes
                if (mem_wstrb[0]) sig_data[mem_addr[8:0] - 9'h080 + 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) sig_data[mem_addr[8:0] - 9'h080 + 1] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) sig_data[mem_addr[8:0] - 9'h080 + 2] <= mem_wdata[23:16];
                if (mem_wstrb[3]) sig_data[mem_addr[8:0] - 9'h080 + 3] <= mem_wdata[31:24];
            end
        end
    end

endmodule
