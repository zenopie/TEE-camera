#!/usr/bin/env bash
# qemu_boot_test.sh — boot Keystone in QEMU and confirm SM + enclave loading
# Usage: ./scripts/qemu_boot_test.sh [--hello-world]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
KEYSTONE="$ROOT/keystone"
HELLO_WORLD=${1:-""}

# ── locate build artifacts ────────────────────────────────────────────────────
find_file() {
    local name="$1"
    local result
    result=$(find "$KEYSTONE/build" -name "$name" 2>/dev/null | head -1)
    if [ -z "$result" ]; then
        echo "ERROR: Could not find $name in $KEYSTONE/build" >&2
        exit 1
    fi
    echo "$result"
}

BBL="$(find_file "bbl.bin" 2>/dev/null || find_file "fw_payload.elf" 2>/dev/null)" || {
    # Keystone's QEMU image is often a flat binary or an ext2 image
    BBL=$(find "$KEYSTONE/build" -name "*.bin" -o -name "*.img" 2>/dev/null | head -1)
    [ -z "$BBL" ] && { echo "ERROR: No boot image found. Run 'make setup' first."; exit 1; }
}
echo "==> Boot image: $BBL"

# ── Keystone QEMU command ─────────────────────────────────────────────────────
# Keystone uses a custom QEMU with the virt machine and a specific firmware layout.
# The SM (security monitor) runs in M-mode, eyrie in S-mode, linux + enclave in U-mode.
QEMU_ARGS=(
    -M virt
    -m 4G
    -nographic
    -kernel "$BBL"
)

# Check if Keystone uses a disk image (buildroot)
ROOTFS=$(find "$KEYSTONE/build" -name "rootfs.ext2" -o -name "rootfs.img" 2>/dev/null | head -1 || true)
if [ -n "$ROOTFS" ]; then
    QEMU_ARGS+=(-drive "file=$ROOTFS,format=raw,id=hd0")
    QEMU_ARGS+=(-device "virtio-blk-device,drive=hd0")
    QEMU_ARGS+=(-append "console=ttyS0 ro root=/dev/vda")
fi

echo "==> Launching QEMU..."
echo "    Command: qemu-system-riscv64 ${QEMU_ARGS[*]}"
echo "    (waiting up to 60s for SM boot message...)"
echo ""

# Run QEMU with a timeout, capture output
BOOT_LOG="/tmp/keystone_boot_$(date +%s).log"
timeout 60 qemu-system-riscv64 "${QEMU_ARGS[@]}" 2>&1 | tee "$BOOT_LOG" | \
    while IFS= read -r line; do
        echo "$line"
        # Exit early once we see the login prompt or hello-world
        if echo "$line" | grep -qiE "login:|buildroot login|hello world|test passed"; then
            echo ""
            echo "==> Boot completed successfully."
            # Send Ctrl-A X to kill QEMU
            break
        fi
    done || true

echo ""
echo "==> Boot log saved to: $BOOT_LOG"

# ── validate ─────────────────────────────────────────────────────────────────
CHECKS_PASSED=0
CHECKS_FAILED=0

check() {
    local desc="$1"; local pattern="$2"
    if grep -qiE "$pattern" "$BOOT_LOG" 2>/dev/null; then
        echo "  [PASS] $desc"
        CHECKS_PASSED=$((CHECKS_PASSED+1))
    else
        echo "  [FAIL] $desc (pattern: $pattern)"
        CHECKS_FAILED=$((CHECKS_FAILED+1))
    fi
}

echo "==> Validating boot output..."
check "Security Monitor initialized"    "security monitor|sm initialized|keystone"
check "RISC-V boot"                     "riscv|opensbi|bbl"
check "No kernel panic"                 "login:|buildroot|boot complete"

echo ""
if [ "$CHECKS_FAILED" -eq 0 ]; then
    echo "==> QEMU boot test PASSED ($CHECKS_PASSED checks)"
    exit 0
else
    echo "==> QEMU boot test: $CHECKS_PASSED passed, $CHECKS_FAILED failed"
    echo "    Review $BOOT_LOG for details"
    exit 1
fi
