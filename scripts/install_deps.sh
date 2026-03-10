#!/usr/bin/env bash
# install_deps.sh — install all system dependencies for TEE-camera
# Tested on Ubuntu 22.04 / 24.04
set -euo pipefail

echo "==> Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y \
    build-essential git cmake ninja-build \
    gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu \
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
    qemu-system-misc \
    libssl-dev \
    python3 python3-pip python3-setuptools python3-wheel \
    device-tree-compiler \
    libglib2.0-dev libfdt-dev libpixman-1-dev \
    autoconf automake libtool flex bison

echo "==> Installing Python packages (LiteX + Migen)..."
# Install in a venv to avoid system package conflicts
python3 -m venv "$HOME/.tee-camera-venv" --system-site-packages 2>/dev/null || true
# shellcheck disable=SC1090
source "$HOME/.tee-camera-venv/bin/activate" 2>/dev/null || true

pip install --upgrade pip
pip install migen
pip install litex
pip install litex-boards 2>/dev/null || echo "  litex-boards install failed (optional for sim)"

echo ""
echo "==> All dependencies installed."
echo "    Next: run ./scripts/setup_keystone.sh"
