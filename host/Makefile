# Makefile for TEE-camera Rust host runner
#
# Dependencies:
#   - Rust toolchain with the riscv64gc-unknown-linux-gnu target
#       rustup target add riscv64gc-unknown-linux-gnu
#   - RISC-V cross-compiler (for the C++ Keystone wrapper)
#   - Keystone SDK (built via ../scripts/setup_keystone.sh)
#
# Variables:
#   KEYSTONE_SDK   path to the Keystone SDK root  (default: ../keystone/sdk)
#   CROSS_COMPILE  RISC-V cross-compiler prefix   (default: riscv64-unknown-linux-gnu-)
#   CARGO_TARGET   Rust target triple             (default: riscv64gc-unknown-linux-gnu)
#
# Targets:
#   all    (default) – build the host binary
#   clean  – remove build artefacts

KEYSTONE_SDK  ?= ../keystone/sdk
CROSS_COMPILE ?= riscv64-unknown-linux-gnu-
CARGO_TARGET  ?= riscv64gc-unknown-linux-gnu

# Export SDK path so build.rs can read it.
export KEYSTONE_SDK

# Tell the cc crate which cross-compiler to use for the C++ wrapper.
export CXX_riscv64gc_unknown_linux_gnu  := $(CROSS_COMPILE)g++
export CC_riscv64gc_unknown_linux_gnu   := $(CROSS_COMPILE)gcc
export AR_riscv64gc_unknown_linux_gnu   := $(CROSS_COMPILE)ar

# Tell Cargo which linker to use when linking the final Rust binary.
export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER := $(CROSS_COMPILE)gcc

.PHONY: all clean

all:
	cargo build --release --target $(CARGO_TARGET)
	cp target/$(CARGO_TARGET)/release/host host

clean:
	cargo clean
	$(RM) host
