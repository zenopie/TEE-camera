# TEE-camera — FPGA Camera Attestation
# iCE40UP5K + Ring Oscillator PUF + Ed25519 hardware signing
#
# Simulation (Docker):
#   make sim-build    — build simulation Docker image
#   make sim          — run all RTL simulations
#   make sim-sha512   — run SHA-512 simulation only
#   make sim-fe25519  — run Ed25519 field arithmetic simulation only
#   make sim-puf      — run PUF simulation only
#
# Synthesis (requires Yosys + nextpnr-ice40):
#   make synth        — synthesize for iCE40UP5K (TODO)
#   make prog         — program via iceprog (TODO)

.PHONY: sim-build sim sim-puf sim-fuzzy-extract sim-boot-keygen sim-frame-hasher sim-uart sim-sha512 sim-fe25519 sim-ed25519-point sim-ed25519-sign clean

OUTPUT := output

sim-build:
	docker build -f Dockerfile.sim -t tee-camera-sim .

sim: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim

sim-puf: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-puf

sim-fuzzy-extract: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-fuzzy-extract

sim-uart: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-uart

sim-frame-hasher: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-frame-hasher

sim-boot-keygen: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-boot-keygen

sim-ed25519-sign: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-ed25519-sign

sim-sha512: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-sha512

sim-fe25519: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-fe25519

sim-ed25519-point: sim-build
	@mkdir -p $(OUTPUT)
	docker run --rm -v $(PWD)/$(OUTPUT):/work/output tee-camera-sim make sim-ed25519-point

clean:
	rm -rf $(OUTPUT)/*.vvp $(OUTPUT)/*.vcd
