# TEE-camera: Trusted Camera Attestation on Open Hardware

Cryptographic proof that video is real, unmodified sensor output — not AI-generated, not edited after capture.

An open-source FPGA captures video from a camera sensor, hashes every raw frame in hardware, and signs the hash chain with an Ed25519 key derived from the chip's unique physical fingerprint (PUF). The signature is embedded in the HDMI output as a binary barcode. A host program reads the HDMI feed and verifies the signature in real time.

**The entire trust chain — from photon to verified signature — runs on auditable open hardware with an open-source toolchain. No proprietary silicon. No black-box firmware.**

---

## How It Works

```
OV7670 Camera ──DVP──> FPGA (ECP5-25K, iCESugar-Pro)
                          ├── Frame Hasher (SHA-512, hardware)
                          ├── PUF → Ed25519 Keypair (RISC-V + monocypher)
                          ├── Frame Buffer (RGB332, 320×240)
                          ├── UART→SCCB Bridge (live camera tuning)
                          └── HDMI Out (640×480 @ 60Hz)
                                ├── Camera feed (top 440 rows)
                                ├── Sync pattern (4 rows)
                                └── Binary barcode (36 rows)
                                      └── pubkey + bundle# + hash + signature
                                                │
                                  Host Program (OpenCV + Ed25519 verify)
                                    ├── Signature verification
                                    └── Live camera tuning (sliders → UART → SCCB)
                                                │
                                          VERIFIED ✓
```

### What gets signed

Every 250 frames, the hardware SHA-512 core produces a chain hash of all raw DVP bytes. The RISC-V CPU signs the hash with the PUF-derived Ed25519 private key. The signature, public key, bundle number, and hash are encoded as a binary barcode in the HDMI output.

### What gets verified

The host program captures the HDMI feed via a USB capture card, decodes the barcode, and verifies the Ed25519 signature. A valid signature proves this specific physical FPGA device produced this footage.

---

## Hardware

| Component | Part | Notes |
|-----------|------|-------|
| FPGA | iCESugar-Pro (LFE5U-25F) | ECP5-25K, open toolchain |
| Camera | OV7670 (no FIFO) | VGA 30fps, RGB565, DVP interface |
| HDMI | Via extension board | 640×480 @ 60Hz, pseudo-differential |
| Capture | Any USB HDMI capture card | For host verification |

### Resource Utilization

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT4 | ~13,600 | 24,288 | 56% |
| DP16KD (BRAM) | 53 | 56 | 95% |
| Flip-flops | ~9,600 | 24,288 | 40% |

---

## Quick Start

### Prerequisites

- [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, nextpnr-ecp5, ecppack, OpenOCD)
- riscv64-unknown-elf-gcc (for firmware)
- Python 3 with OpenCV, cryptography, and pyserial
- iCESugar-Pro connected via USB

### Build & Flash

```bash
# Build firmware
cd firmware && make && cp firmware.hex .. && cd ..

# Source toolchain
source ~/tools/oss-cad-suite/environment

# Build and flash FPGA
make build
```

### Run Host Verifier

```bash
cd host
python3 -m venv .venv
.venv/bin/pip install opencv-python cryptography numpy pyserial
.venv/bin/python3 hdmi_host.py --device 0
```

The host auto-detects the UART serial port for live camera tuning. If connected, you get sliders for:
- **Red / Green / Blue** gain
- **Brightness / Contrast**
- **Sharpness / Denoise**
- **AWB** (auto white balance toggle)

Press `p` to print current register values, `q` to quit.

---

## Directory Structure

```
TEE-camera/
├── Makefile                    # Build targets: synth, pnr, flash, build
├── firmware.hex                # Compiled firmware (checked in for convenience)
│
├── rtl/                        # Synthesizable Verilog
│   ├── fpga_top.v              # Top level: clocks, camera, HDMI, SoC
│   ├── soc_top.v               # RISC-V SoC: PicoRV32 + peripherals
│   ├── picorv32.v              # RISC-V CPU core
│   ├── framebuf.v              # Dual-port frame buffer (RGB332)
│   ├── hdmi_out.v              # HDMI output: PLL, VGA timing, TMDS
│   ├── tmds_encoder.v          # TMDS 8b/10b encoder
│   ├── frame_hasher.v          # DVP stream → SHA-512 hash chain
│   ├── puf.v                   # Ring oscillator PUF (128 cells)
│   ├── fuzzy_extract.v         # Majority vote fuzzy extractor
│   ├── ov7670_init.v           # OV7670 SCCB register init + UART command handler
│   ├── sccb_master.v           # SCCB (I2C-like) master
│   ├── uart_tx.v               # UART transmitter
│   ├── uart_rx.v               # UART receiver (for live camera tuning)
│   └── sha512/                 # SHA-512 core (secworks, BSD license)
│
├── firmware/                   # RISC-V firmware (C)
│   ├── main.c                  # PUF → keygen → sign loop
│   ├── monocypher.c/h          # Ed25519 + SHA-512 (software)
│   └── hw.h                    # Hardware register interface
│
├── fpga/                       # FPGA constraint files
│   ├── icesugar_pro.lpf        # Pin constraints
│   └── cmsisdap.cfg            # OpenOCD config
│
├── host/                       # Host programs
│   └── hdmi_host.py            # Capture HDMI, verify signatures, camera tuning sliders
│
└── sim/                        # Testbenches
    └── tb_soc.v                # SoC simulation
```

---

## Camera Configuration

The OV7670 operates in **RGB565 mode** (COM7=0x04, COM15=0xD0). The FPGA captures 2 bytes per pixel and extracts RGB332 via bit manipulation — no YUV conversion needed.

On startup, the host program sends the full Linux kernel OV7670 register set (~70 registers) via the UART→SCCB bridge, configuring gamma curves, AGC/AEC parameters, lens correction, and the color matrix for proper image quality.

---

## Security Model

- **PUF key derivation** — private key derived from silicon physics at every boot, never stored
- **Volatile keys** — power off = key gone, only the public key persists (in host records)
- **Open hardware** — full RTL is auditable, open-source toolchain, no proprietary blobs
- **Frame binding** — bundle number prevents replay/reorder attacks
- **Chain hash** — 250 frames cryptographically linked per signature
- **Tamper evidence** — SHA-512 hash covers exact raw sensor bytes

The signature proves "this specific physical device produced this footage." Combined with the open-source auditable design, this is sufficient to distinguish real camera footage from AI-generated or edited content.

---

## License

MIT
