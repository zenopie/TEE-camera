# TEE-camera: Trusted Camera Attestation

Pre-hardware software stack for a trusted camera system using:
- **Keystone** (RISC-V TEE) for frame signing in a hardware enclave
- **iCESugar Pro** (iCE40UP5K FPGA) as the open hardware platform
- **LiteX + VexRiscv** for the SoC, simulated with `litex_sim` before hardware

Reference: https://forum.scrt.network/t/trusted-camera-attestation-on-open-hardware-a-pathway-to-production-ready-open-tees/7960

---

## Directory Structure

```
TEE-camera/
├── Makefile                    # Top-level: setup / run / verify / sim
├── scripts/
│   ├── install_deps.sh         # Install system packages
│   ├── setup_keystone.sh       # Clone + build Keystone from source
│   └── qemu_boot_test.sh       # Boot SM in QEMU, validate output
├── enclave/
│   ├── common.h                # Shared types (host ↔ enclave)
│   ├── enclave.c               # Frame signing eapp (Ed25519 + SHA-256)
│   ├── tweetnacl.{h,c}         # TweetNaCl Ed25519 (no external deps)
│   ├── sha256.{h,c}            # SHA-256 (no external deps)
│   └── Makefile                # Cross-compile for RISC-V
├── host/
│   ├── host.cpp                # Keystone host: loads enclave, feeds frames
│   └── Makefile
├── verifier/
│   ├── verifier.c              # Standalone x86 verifier
│   └── Makefile
├── litex/
│   ├── icesugar_pro.py         # iCE40UP5K platform definition
│   ├── soc.py                  # SoC: VexRiscv + SPRAM + PMP-aware DMA
│   ├── sim.py                  # litex_sim simulation target
│   └── Makefile
└── keystone/
    └── platform/litex/         # Keystone platform port for LiteX SoC
        ├── platform.h
        ├── platform.c
        └── config.h
```

---

## Quick Start

### 1. Install dependencies

```bash
./scripts/install_deps.sh
```

Installs: `qemu-system-riscv64`, `gcc-riscv64-linux-gnu`, `libssl-dev`, LiteX, Migen.

### 2. Build Keystone

```bash
./scripts/setup_keystone.sh
```

Clones `https://github.com/keystone-enclave/keystone`, builds the Security Monitor,
Eyrie runtime, and SDK. Runs a smoke-test in QEMU. Takes ~10 minutes.

### 3. Sign frames in QEMU

```bash
make run
# or with custom params:
make run FRAMES=30 WIDTH=640 HEIGHT=480 FPS=30
```

Builds the enclave + host, boots Keystone in QEMU, generates synthetic frames,
signs each one inside the enclave, writes `output/frames/frame_NNNNNN.sig`.

### 4. Verify signed frames

```bash
make verify
```

Verifies all `.sig` files: Ed25519 signature, SHA-256 hash, sequence continuity,
monotonic counter.

### 5. Test gap detection

```bash
make test-gap
```

Runs `make run`, drops frame 5, re-runs verifier — confirms gap is caught.

### 6. Simulate the LiteX SoC

```bash
make sim
```

Boots the iCE40UP5K SoC (VexRiscv + SPRAM + PMP-aware DMA) in `litex_sim`.
The DMA controller refuses to write frames unless a valid PMP entry covers
the destination — verified in simulation.

---

## Architecture

### Enclave (enclave/)

The signing enclave runs inside Keystone's hardware-isolated TEE:

1. **Key derivation**: at init, calls `sm_get_sealing_key()` to get an
   enclave-specific secret, uses it as the Ed25519 seed.
2. **Frame signing**: for each frame:
   - SHA-256 hash the raw frame bytes
   - Build message: `hash || sequence (LE u64) || monotonic_ts (LE u64)`
   - Sign with Ed25519 private key
   - Return `SignedFrame` struct via shared memory
3. **No #ifdefs**: signing logic is identical between QEMU and real hardware.
   Only the frame source changes (synthetic vs DMA).

### PMP-Aware DMA Controller (litex/soc.py)

The novel hardware contribution. Implemented in Migen RTL (not software):

- Before any DMA write, the `PMPChecker` module evaluates all 8 PMP entries
  against the destination address range.
- A write is permitted only if a PMP entry with `L+A=NAPOT` (locked, enclave)
  covers the entire destination range.
- If no valid PMP entry covers the destination, `pmp_violation` is asserted
  and the write does not occur.
- This enforcement is in combinational/FSM logic — it cannot be bypassed by
  software running on the CPU.

### Signed Frame Format

```c
typedef struct {
    uint64_t sequence;          // monotonically increasing, 0-based
    uint64_t monotonic_ts;      // cycle counter at signing time
    uint8_t  frame_hash[32];    // SHA-256 of raw frame bytes
    uint8_t  sig[64];           // Ed25519 signature
    uint8_t  pubkey[32];        // Ed25519 public key
    uint32_t width, height;     // frame dimensions
    uint32_t format;            // 0=rgb, 1=gray, 2=synthetic
    uint32_t frame_size;        // bytes in this frame
} SignedFrame;
```

### Verifier

Standalone x86 binary, no Keystone dependency. Given a list of `.sig` files:
- Verifies Ed25519 signature (message = hash || sequence || ts)
- Checks sequence numbers are contiguous
- Checks monotonic_ts is non-decreasing
- Exits 0 on full pass, 1 on any failure

---

## Hardware Path (when iCESugar Pro arrives)

The only required change is in the host runner: replace the synthetic frame
generator with a read from the PMOD camera DMA buffer. The enclave signing
code is unchanged.

1. Synthesize the SoC: `make -C litex synth`
2. Flash: `iceprog build/icesugar_pro.bin`
3. Update host to read from DMA buffer instead of synthetic generator
4. Run as before

---

## Security Notes

- The Ed25519 private key never leaves the enclave's isolated memory.
- Frame signing happens inside the TEE; the host only sees the signed struct.
- The PMP-aware DMA prevents an attacker from redirecting camera DMA to
  non-enclave memory, which would allow frame substitution.
- Monotonic counter and sequence numbers prevent replay attacks.
- Gaps in sequence numbers indicate dropped/censored frames.
