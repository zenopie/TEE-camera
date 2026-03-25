# TEE-camera — FPGA Camera Attestation
# ECP5-25K (iCESugar-Pro) + PUF + Ed25519 signing + HDMI output

OUTPUT := output
TOOLCHAIN := source ~/tools/oss-cad-suite/environment

RTL := rtl/picorv32.v rtl/soc_top.v rtl/puf.v rtl/fuzzy_extract.v \
       rtl/sha512/sha512_core.v rtl/sha512/sha512_k_constants.v rtl/sha512/sha512_w_mem.v \
       rtl/frame_hasher.v rtl/uart_tx.v rtl/tmds_encoder.v rtl/hdmi_out.v \
       rtl/framebuf.v rtl/fpga_top.v rtl/ov7670_init.v rtl/sccb_master.v

.PHONY: firmware synth pnr flash build host clean

# Firmware
firmware:
	cd firmware && make && cp firmware.hex ..

# Synthesis
synth:
	@mkdir -p $(OUTPUT)
	yosys -p "read_verilog $(RTL); synth_ecp5 -abc2 -top fpga_top -json $(OUTPUT)/soc.json" \
		> $(OUTPUT)/synth_soc.log 2>&1
	@grep -E 'LUT4|DP16KD|TRELLIS_FF' $(OUTPUT)/synth_soc.log | tail -3

# Place & Route
pnr: synth
	nextpnr-ecp5 --25k --package CABGA256 --speed 6 \
		--json $(OUTPUT)/soc.json --lpf fpga/icesugar_pro.lpf \
		--textcfg $(OUTPUT)/soc.config --ignore-loops \
		> $(OUTPUT)/pnr_soc.log 2>&1
	ecppack $(OUTPUT)/soc.config --svf $(OUTPUT)/soc.svf

# Flash to FPGA
flash:
	openocd -f fpga/cmsisdap.cfg \
		-c "init; svf -tap ecp5.tap -quiet -progress $(OUTPUT)/soc.svf; exit;"

# Full build + flash
build: pnr flash

# Host program
host:
	cd host && .venv/bin/python3 hdmi_host.py --device 0

clean:
	rm -rf $(OUTPUT)/*.json $(OUTPUT)/*.config $(OUTPUT)/*.svf $(OUTPUT)/*.log
