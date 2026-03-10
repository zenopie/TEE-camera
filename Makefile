# TEE-camera — Trusted Camera Attestation
# Pre-hardware software stack for iCESugar Pro (iCE40UP5K) + Keystone QEMU
#
# Targets:
#   make setup      — install deps + build Keystone (run once)
#   make sim        — boot LiteX SoC in litex_sim
#   make run        — generate synthetic frames, sign in Keystone QEMU enclave
#   make verify     — verify a signed frame file (set FRAMES=dir/)
#   make test-gap   — demonstrate sequence gap detection
#   make clean      — remove build artifacts

.PHONY: setup sim run verify test-gap clean all enclave host verifier

# ── paths ─────────────────────────────────────────────────────────────────────
ROOT        := $(shell pwd)
KEYSTONE    := $(ROOT)/keystone
SDK         := $(KEYSTONE)/sdk
EYRIE_RT    := $(KEYSTONE)/sdk/rts/eyrie/eyrie-rt
ENCLAVE_DIR := $(ROOT)/enclave
HOST_DIR    := $(ROOT)/host
VERIFIER_DIR:= $(ROOT)/verifier
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

# ── build verifier (native x86) ───────────────────────────────────────────────
verifier:
	@echo "==> Building verifier..."
	$(MAKE) -C $(VERIFIER_DIR)

# ── run: sign synthetic frames in QEMU enclave ────────────────────────────────
run: enclave host verifier
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
verify: verifier
	@echo "==> Verifying signed frames in $(FRAME_DIR)..."
	$(VERIFIER_DIR)/verifier $(FRAME_DIR)/frame_*.sig
	@echo "==> Verification complete."

# ── gap detection test: drop frame 5 and verify ──────────────────────────────
test-gap: verify
	@echo "==> Testing sequence gap detection..."
	@echo "    Removing frame 000005 to create a gap..."
	@rm -f $(FRAME_DIR)/frame_000005.sig
	@echo "    Running verifier (should detect gap)..."
	$(VERIFIER_DIR)/verifier $(FRAME_DIR)/frame_*.sig; \
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

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	$(MAKE) -C $(ENCLAVE_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(HOST_DIR)    clean 2>/dev/null || true
	$(MAKE) -C $(VERIFIER_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(LITEX_DIR)   clean 2>/dev/null || true
	rm -rf $(OUTPUT_DIR)

all: enclave host verifier
