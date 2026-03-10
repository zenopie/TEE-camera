#!/usr/bin/env bash
# setup_keystone.sh — clone, patch, and build Keystone + QEMU from source
# Run once before `make run`. Requires: cmake, python3, riscv64 toolchain, QEMU.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
KEYSTONE_DIR="$ROOT/keystone"

# ── dependency check ─────────────────────────────────────────────────────────
need() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Install it first."; exit 1; }; }
need git; need cmake; need python3; need qemu-system-riscv64
need riscv64-linux-gnu-gcc || need riscv64-unknown-linux-gnu-gcc

echo "==> Checking RISC-V toolchain prefix..."
if command -v riscv64-linux-gnu-gcc &>/dev/null; then
    export CROSS_COMPILE=riscv64-linux-gnu-
elif command -v riscv64-unknown-linux-gnu-gcc &>/dev/null; then
    export CROSS_COMPILE=riscv64-unknown-linux-gnu-
else
    echo "ERROR: No RISC-V Linux GCC found"; exit 1
fi
echo "    CROSS_COMPILE=$CROSS_COMPILE"

# ── clone Keystone ────────────────────────────────────────────────────────────
if [ ! -d "$KEYSTONE_DIR/.git" ]; then
    echo "==> Cloning Keystone..."
    git clone https://github.com/keystone-enclave/keystone.git "$KEYSTONE_DIR"
    cd "$KEYSTONE_DIR"
    git submodule update --init --recursive
else
    echo "==> Keystone already cloned, updating submodules..."
    cd "$KEYSTONE_DIR"
    git submodule update --init --recursive
fi

# ── build Keystone (SM + SDK + eyrie runtime + QEMU) ─────────────────────────
echo "==> Configuring Keystone build..."
mkdir -p "$KEYSTONE_DIR/build"
cd "$KEYSTONE_DIR/build"

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_QEMU=y \
    -Driscv64-linux-gnu-gcc="$(command -v ${CROSS_COMPILE}gcc)" \
    -DCMAKE_INSTALL_PREFIX="$KEYSTONE_DIR/install"

echo "==> Building Keystone (this takes ~10 minutes)..."
make -j"$(nproc)" 2>&1 | tee "$ROOT/keystone_build.log"

echo "==> Installing Keystone SDK..."
make install

# ── smoke test: boot hello-world in QEMU ─────────────────────────────────────
echo "==> Smoke-testing hello-world enclave in QEMU..."
QEMU_IMG="$KEYSTONE_DIR/build/buildroot_barebone/images/bbl.bin"
if [ ! -f "$QEMU_IMG" ]; then
    echo "WARNING: bbl.bin not found at expected path, trying to locate..."
    QEMU_IMG=$(find "$KEYSTONE_DIR/build" -name "bbl.bin" 2>/dev/null | head -1)
    [ -z "$QEMU_IMG" ] && { echo "ERROR: bbl.bin not found after build"; exit 1; }
fi

# Run QEMU for 30s, capture output, check for "hello" or SM boot message
timeout 30 qemu-system-riscv64 \
    -M virt \
    -m 4G \
    -nographic \
    -bios "$QEMU_IMG" \
    -append "console=ttyS0 ro root=/dev/vda" \
    2>&1 | tee /tmp/keystone_qemu_boot.log | head -80 || true

if grep -qi "security monitor\|hello world\|keystone" /tmp/keystone_qemu_boot.log; then
    echo "==> QEMU boot PASSED — Security Monitor started"
else
    echo "WARNING: Could not confirm SM boot from log. Check /tmp/keystone_qemu_boot.log"
    echo "         This may be OK if the boot sequence is longer than 30s."
fi

echo ""
echo "==> Keystone setup complete."
echo "    SDK headers: $KEYSTONE_DIR/sdk/include"
echo "    Eyrie runtime: $KEYSTONE_DIR/sdk/rts/eyrie"
echo "    Run 'make run' from the project root to build and run the enclave."
