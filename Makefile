# TEE-camera — Trusted Camera Attestation
# Pre-hardware software stack for iCESugar Pro (iCE40UP5K) + Keystone QEMU
#
# Quick start with Docker:
#   make docker-demo              — run demo in Docker (no deps needed)
#   make docker-build             — build full stack with Keystone (~15 min)
#   make docker-shell             — interactive shell in build environment
#
# Native targets:
#   make setup      — install deps + build Keystone (run once)
#   make demo       — generate test frames locally (no QEMU)
#   make run        — sign frames in Keystone QEMU enclave
#   make verify     — verify signed frames
#   make clean      — remove build artifacts

.PHONY: setup sim run verify test-gap clean all enclave host tools
.PHONY: docker-demo docker-build docker-shell docker-clean

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT        := $(shell pwd)
KEYSTONE    := $(ROOT)/keystone
SDK         := $(KEYSTONE)/sdk
EYRIE_RT    := $(KEYSTONE)/sdk/rts/eyrie/eyrie-rt
ENCLAVE_DIR := $(ROOT)/enclave
HOST_DIR    := $(ROOT)/host
TOOLS_DIR   := $(ROOT)/tools
LITEX_DIR   := $(ROOT)/litex
OUTPUT_DIR  := $(ROOT)/output

# ── configurable parameters ───────────────────────────────────────────────────
FRAMES  ?= 10
WIDTH   ?= 320
HEIGHT  ?= 240
FPS     ?= 10
FRAME_DIR ?= $(OUTPUT_DIR)/frames

# ── setup ─────────────────────────────────────────────────────────────────────
setup:
	@echo "==> Installing dependencies..."
	@bash scripts/install_deps.sh
	@echo "==> Building Keystone..."
	@bash scripts/setup_keystone.sh

# ── build enclave ─────────────────────────────────────────────────────────────
enclave:
	@echo "==> Building frame signing enclave..."
	$(MAKE) -C $(ENCLAVE_DIR) KEYSTONE_SDK=$(SDK)

# ── build host runner ─────────────────────────────────────────────────────────
host:
	@echo "==> Building host runner..."
	$(MAKE) -C $(HOST_DIR) KEYSTONE_SDK=$(SDK)

# ── build tools (verifier, test frame generator) ─────────────────────────────
tools:
	@echo "==> Building tools..."
	$(MAKE) -C $(TOOLS_DIR)

# ── run: sign synthetic frames in QEMU enclave ────────────────────────────────
run: enclave host tools
	@echo "==> Creating output directory..."
	@mkdir -p $(FRAME_DIR)
	@echo "==> Running host runner ($(FRAMES) frames @ $(WIDTH)x$(HEIGHT) $(FPS)fps)..."
	$(HOST_DIR)/host \
	    --enclave $(ENCLAVE_DIR)/enclave.eapp \
	    --runtime $(EYRIE_RT) \
	    --frames  $(FRAMES) \
	    --width   $(WIDTH) \
	    --height  $(HEIGHT) \
	    --fps     $(FPS) \
	    --output  $(FRAME_DIR)
	@echo "==> Signed frames written to $(FRAME_DIR)"
	@ls -lh $(FRAME_DIR)

# ── verify signed frames ──────────────────────────────────────────────────────
verify: tools
	@echo "==> Verifying signed frames in $(FRAME_DIR)..."
	$(TOOLS_DIR)/verify_frames -v $(FRAME_DIR)/frame_*.signed
	@echo "==> Verification complete."

# ── gap detection test: drop frame 5 and verify ──────────────────────────────
test-gap: verify
	@echo "==> Testing sequence gap detection..."
	@echo "    Removing frame 000005 to create a gap..."
	@rm -f $(FRAME_DIR)/frame_000005.signed
	@echo "    Running verifier (should detect gap)..."
	$(TOOLS_DIR)/verify_frames $(FRAME_DIR)/frame_*.signed; \
	    STATUS=$$?; \
	    if [ $$STATUS -ne 0 ]; then \
	        echo "PASS: Verifier detected the sequence gap (exit $$STATUS)"; \
	    else \
	        echo "FAIL: Verifier did not detect the gap"; exit 1; \
	    fi

# ── LiteX simulation ──────────────────────────────────────────────────────────
sim:
	@echo "==> Running LiteX SoC simulation..."
	$(MAKE) -C $(LITEX_DIR) sim

# ── demo: generate test frames locally (no QEMU needed) ──────────────────────
demo: tools
	@echo "==> Running local demo (synthetic frames, no TEE)..."
	@mkdir -p $(FRAME_DIR)
	$(TOOLS_DIR)/generate_test_frames $(FRAMES) $(WIDTH) $(HEIGHT) $(FRAME_DIR)
	@echo ""
	$(TOOLS_DIR)/verify_frames -v $(FRAME_DIR)/frame_*.signed

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	$(MAKE) -C $(ENCLAVE_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(HOST_DIR)    clean 2>/dev/null || true
	$(MAKE) -C $(TOOLS_DIR)   clean 2>/dev/null || true
	$(MAKE) -C $(LITEX_DIR)   clean 2>/dev/null || true
	rm -rf $(OUTPUT_DIR)

all: enclave host tools

# ══════════════════════════════════════════════════════════════════════════════
# Docker targets (no local dependencies needed)
# ══════════════════════════════════════════════════════════════════════════════

# Quick demo - builds tools and generates test frames
docker-demo:
	@echo "==> Running demo in Docker..."
	docker build -t tee-camera .
	docker run --rm -v "$(PWD)/output:/work/output" tee-camera \
	    make demo FRAMES=$(FRAMES) WIDTH=$(WIDTH) HEIGHT=$(HEIGHT)
	@echo ""
	@echo "==> Output in ./output/frames/"

# Full build with Keystone (takes ~15 min first time)
docker-build:
	@echo "==> Building full stack in Docker (this takes ~15 min first time)..."
	docker build -f Dockerfile.full -t tee-camera-full .

# Interactive shell
docker-shell:
	docker run -it --rm -v "$(PWD):/work" -v "$(PWD)/output:/work/output" \
	    tee-camera /bin/bash

# Clean docker images
docker-clean:
	docker rmi tee-camera tee-camera-full 2>/dev/null || true
