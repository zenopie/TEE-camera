# TEE-camera: Trusted Camera Attestation on Open Hardware

Cryptographic frame signing in pure FPGA hardware — no CPU, no firmware, no attack surface.

- **iCE40UP5K FPGA** — fully open toolchain (Yosys + nextpnr)
- **Ed25519 signatures** — custom Verilog implementation (novel open-source contribution)
- **Ring Oscillator PUF** — silicon fingerprint for key derivation, no secrets in flash
- **SHA-512** — used for everything: key derivation, frame hashing, Ed25519 internals

Every video frame is hashed and signed in hardware. The private key is derived from the physical silicon at boot and never exists outside the FPGA fabric.

---

## Architecture

```
┌─────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌──────────────┐
│  PUF    │───>│  Fuzzy   │───>│ SHA-512  │───>│  Ed25519     │───>│  Ed25519     │
│  Ring   │    │  Extract │    │ Key Hash │    │  Scalar      │    │  Public Key  │
│  Osc.   │    │  7-vote  │    │          │    │  Clamping    │    │  A = [s]B    │
└─────────┘    └──────────┘    └──────────┘    └──────────────┘    └──────────────┘
  128 bits       128 bits        512 bits        256 bits            Extended point
                                                                   ─── BOOT (once) ───

┌──────────┐    ┌──────────┐    ┌──────────────────┐    ┌──────────┐
│  Camera  │───>│ SHA-512  │───>│  Ed25519 Sign    │───>│  Output  │
│  DVP     │    │ Frame    │    │  R,S = sign(msg)  │    │  Frame + │
│  Capture │    │ Hash     │    │                    │    │  Sig     │
└──────────┘    └──────────┘    └──────────────────┘    └──────────┘
                                                   ─── PER FRAME ───
```

### Boot Flow (boot_keygen)

1. **PUF measurement** — ring oscillator cells measured 7 times each
2. **Fuzzy extraction** — majority vote per bit for noise suppression
3. **SHA-512 hash** — expand 128 PUF bits to 512 bits of key material
4. **Scalar clamping** — RFC 8032 clamping (clear bits 0-2,255; set bit 254)
5. **Public key** — compute A = [s]B via scalar multiplication (~14ms at 24MHz)

### Per-Frame Signing (ed25519_sign)

1. **Nonce** — r = SHA-512(prefix || frame_hash) mod L
2. **Nonce point** — R = [r]B
3. **Challenge** — k = SHA-512(R || A || frame_hash) mod L
4. **Signature** — S = (r + k*s) mod L, output (R, S)

---

## Directory Structure

```
TEE-camera/
├── Makefile                    # Docker simulation targets
├── Makefile.sim                # Inner iverilog simulation targets
├── Dockerfile.sim              # Alpine + Icarus Verilog
│
├── rtl/                        # Synthesizable Verilog
│   ├── puf.v                   # Ring oscillator PUF (128 cells)
│   ├── fuzzy_extract.v         # Majority vote fuzzy extractor
│   ├── boot_keygen.v           # Boot key derivation controller
│   │
│   ├── sha512/                 # SHA-512 (secworks, BSD license)
│   │   ├── sha512_core.v       # 80-round SHA-512 core
│   │   ├── sha512_k_constants.v
│   │   ├── sha512_h_constants.v
│   │   └── sha512_w_mem.v      # Message schedule (16-word window)
│   │
│   └── ed25519/                # Ed25519 (custom, novel implementation)
│       ├── fe25519.v           # Field arithmetic mod 2^255-19
│       ├── ed25519_point.v     # Point add/double (extended coords)
│       ├── ed25519_scalarmult.v # Left-to-right double-and-add
│       └── ed25519_sign.v      # Full signing controller
│
├── sim/                        # Testbenches
│   ├── tb_puf.v                # PUF basic test
│   ├── tb_fuzzy_extract.v      # Fuzzy extractor consistency test
│   ├── tb_sha512.v             # SHA-512("abc") + SHA-512("")
│   ├── tb_fe25519.v            # 12 field arithmetic tests
│   ├── tb_ed25519_point.v      # Point ops + on-curve checks
│   ├── tb_ed25519_sign.v       # End-to-end signing test
│   └── tb_boot_keygen.v        # Full boot key derivation test
│
└── output/                     # Simulation artifacts (.vvp, .vcd)
```

---

## Quick Start

### Simulate (Docker + Icarus Verilog)

```bash
# Run all simulations
make sim

# Run individual tests
make sim-puf              # PUF basic test
make sim-fuzzy-extract    # Fuzzy extractor
make sim-sha512           # SHA-512
make sim-fe25519          # Field arithmetic (12 tests)
make sim-ed25519-point    # Point operations
make sim-ed25519-sign     # End-to-end signing
make sim-boot-keygen      # Full boot key derivation
```

All tests pass:
- PUF produces deterministic 128-bit output (simulation mode)
- Fuzzy extractor output is consistent across runs
- SHA-512 matches NIST test vectors
- Field arithmetic correct for add/sub/mul including edge cases
- Ed25519 point operations verified on-curve
- Full signing produces valid S < L
- Boot keygen: clamped scalar + public key on curve

---

## Hardware Target

**iCE40UP5K** (Lattice):
- 5,280 LUTs, 8 DSP blocks (SB_MAC16), 128KB SPRAM, 30KB BRAM
- Fully open toolchain: Yosys (synthesis) + nextpnr-ice40 (place & route)
- ~24 MHz clock

### LUT Budget (estimated)

| Module | LUTs |
|--------|------|
| PUF (128 cells) | ~150 |
| SHA-512 core | ~3,000 |
| Ed25519 field arithmetic | ~1,500 |
| Camera DVP + glue | ~400 |
| **Total** | **~5,050 / 5,280** |

### Timing (estimated at 24 MHz)

- Boot key derivation: ~15ms (fuzzy extract + SHA-512 + scalar mult)
- Per-frame signing: ~29ms (2 SHA-512 + scalar mult + arithmetic)
- Supports ~34 fps continuous signing

---

## Security Properties

- **No CPU, no firmware** — signing logic is hardwired in FPGA fabric, no software attack surface
- **PUF key derivation** — private key derived from silicon at every boot, never stored in flash
- **Volatile keys** — key material exists only in FPGA registers while powered; power-off = gone
- **Tamper evidence** — SHA-512 hash binds signature to exact frame bytes
- **Open hardware** — full design is auditable, no proprietary blobs

### Future: NVCM Key Storage

iCE40 has one-time-programmable NVCM fuses. For production, the PUF fingerprint could be burned into NVCM at manufacture for a permanent device identity, with the security bit set to prevent readback. The current PUF approach is used during development.

---

## Ed25519 Implementation

This project includes a novel open-source Ed25519 implementation in Verilog, designed for small FPGAs. No existing open-source Verilog Ed25519 was available for iCE40-class devices.

**Key design choices:**
- Extended twisted Edwards coordinates (X,Y,Z,T) — avoids expensive inversions
- Unified add formula (add-2008-hwcd-4): 8M + 8add, no multiply by curve constant d
- Doubling formula (dbl-2008-hwcd): 4M + 4S + 6add, uses a = -1
- Single field multiplier with microcode sequencer — fits in ~1,500 LUTs
- Behavioral simulation uses Verilog `*` operator; hardware target will use iterative DSP (SB_MAC16)

---

## License

MIT
