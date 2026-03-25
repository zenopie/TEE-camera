# FPGA synthesis Makefile for iCESugar-Pro (ECP5 LFE5U-25F)

DEVICE  = 25k
PACKAGE = CABGA256
SPEED   = 6
CFG     = cmsisdap.cfg
RTL     = ../rtl

# RTL source files for full design
# Time-shared architecture: 1 SHA-512, 1 fe25519, 1 ed25519_point
SRCS = $(RTL)/fpga_top.v \
       $(RTL)/camera_top.v \
       $(RTL)/mod_l_reduce.v \
       $(RTL)/wide_mul.v \
       $(RTL)/sccb_master.v \
       $(RTL)/ov7670_init.v \
       $(RTL)/frame_hasher.v \
       $(RTL)/puf.v \
       $(RTL)/fuzzy_extract.v \
       $(RTL)/uart_tx.v \
       $(RTL)/ed25519/ed25519_point.v \
       $(RTL)/ed25519/fe25519.v \
       $(RTL)/sha512/sha512_core.v \
       $(RTL)/sha512/sha512_k_constants.v \
       $(RTL)/sha512/sha512_h_constants.v \
       $(RTL)/sha512/sha512_w_mem.v

# === Full camera design ===
all: camera.svf
	@echo "=== Camera bitstream ready. Run: make prog ==="

camera.json: $(SRCS)
	yosys -p "read_verilog $(SRCS); synth_ecp5 -abc2 -top fpga_top -json camera.json"

camera.config: camera.json icesugar_pro.lpf
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
		--json camera.json --lpf icesugar_pro.lpf --textcfg camera.config \
		--ignore-loops

camera.bit: camera.config
	ecppack --compress --input camera.config --bit camera.bit

camera.svf: camera.config
	ecppack --compress --input camera.config --svf camera.svf

prog: camera.svf
	openocd -f $(CFG) -c "init; svf -tap ecp5.tap -quiet -progress camera.svf; exit;"

# === Blink test ===
blink: blink.svf
	@echo "=== Blink ready. Run: make prog-blink ==="

blink.json: blink.v
	yosys -p "read_verilog blink.v; synth_ecp5 -json blink.json -top blink"

blink.config: blink.json blink.lpf
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
		--json blink.json --lpf blink.lpf --textcfg blink.config

blink.svf: blink.config
	ecppack --compress --input blink.config --svf blink.svf

prog-blink: blink.svf
	openocd -f $(CFG) -c "init; svf -tap ecp5.tap -quiet -progress blink.svf; exit;"

# === Camera connectivity test (lightweight, no SHA-512) ===
TEST_SRCS = cam_test.v \
            $(RTL)/sccb_master.v \
            $(RTL)/ov7670_init.v \
            $(RTL)/uart_tx.v

test: cam_test.svf
	@echo "=== Test ready. Run: make prog-test ==="

cam_test.json: $(TEST_SRCS)
	yosys -p "read_verilog $(TEST_SRCS); synth_ecp5 -json cam_test.json -top cam_test"

cam_test.config: cam_test.json icesugar_pro.lpf
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
		--json cam_test.json --lpf icesugar_pro.lpf --textcfg cam_test.config

cam_test.svf: cam_test.config
	ecppack --compress --input cam_test.config --svf cam_test.svf

prog-test: cam_test.svf
	openocd -f $(CFG) -c "init; svf -tap ecp5.tap -quiet -progress cam_test.svf; exit;"

clean:
	rm -f *.json *.config *.bit *.svf

.PHONY: all prog blink prog-blink test prog-test clean
