# TEE-camera: Trusted Camera Attestation on Open Hardware

Cryptographic frame signing inside a RISC-V hardware enclave.

- **Keystone TEE** for isolated execution (Security Monitor + Eyrie runtime)
- **Ed25519 signatures** via [compact25519](https://github.com/DavyLandman/compact25519) (public domain, bare-metal safe)
- **Multi-threaded host** with producer/consumer frame queue
- **iCESugar Pro FPGA** (iCE40UP5K) as the target open hardware platform

Every video frame is hashed, signed, and timestamped inside the TEE. The private key never leaves the enclave. Dropped or tampered frames are cryptographically detectable.

---

## Architecture

### Two-Thread Design

```
┌──────────────┐       ┌─────────────────┐       ┌──────────────────┐
│ Capture      │       │  Frame Queue    │       │  Keystone        │
│ Thread       │──────>│  (mutex/condvar)│──────>│  Enclave         │
│              │ push  │  [16 slots]     │  pop  │                  │
│ camera/test  │       │                 │ ocall │  Ed25519 sign    │
│ frame hashes │       │                 │       │  loop forever    │
└──────────────┘       └─────────────────┘       └──────────────────┘
     HOST THREAD 1            SHARED              HOST THREAD 2 (main)
                                                  runs enclave.run()
```

**Capture thread** produces frame hashes into a thread-safe queue. **Main thread** runs the Keystone enclave, whose ocall handlers pull frames from the queue. The enclave loops forever; the host destroys it when capture is done.

### Enclave Flow

1. **Init**: Request seed via ocall, derive Ed25519 keypair (`compact_ed25519_keygen`)
2. **Publish**: Send public key to host via ocall
3. **Sign loop** (runs forever):
   - Request frame hash via ocall (blocks until queue has data)
   - Build message: `hash(32) || sequence(8) || timestamp(8)`
   - Sign with Ed25519 (`compact_ed25519_sign`)
   - Return signature + metadata via ocall

### Signed Frame Header

```c
typedef struct __attribute__((packed)) {
    uint32_t magic;           // 0x5347464D ("SGFM")
    uint32_t version;         // Protocol version (1)
    uint32_t header_size;     // sizeof(SignedFrameHeader)
    uint64_t sequence;        // Monotonically increasing frame number
    uint64_t monotonic_ts;    // Timestamp (cycles via rdcycle)
    uint8_t  frame_hash[32];  // SHA-256 of raw frame data
    uint8_t  sig[64];         // Ed25519 signature
    uint8_t  pubkey[32];      // Ed25519 public key
    uint32_t width, height;   // Frame dimensions
    uint32_t format;          // Pixel format
    uint32_t frame_size;      // Raw frame size in bytes
} SignedFrameHeader;
```

---

## Directory Structure

```
TEE-camera/
├── Dockerfile.keystone         # Full Keystone + QEMU build environment
├── Makefile                    # Top-level build orchestration
│
└── examples/frame-sign/        # Keystone SDK example (CMake-based)
    ├── CMakeLists.txt          # Builds eapp + host, packages .ke
    ├── app.lds                 # RISC-V linker script for enclave
    ├── shared_mem.h            # Shared types (FrameRequest, SignatureResult)
    │
    ├── eapp/                   # Enclave application (bare-metal RISC-V)
    │   ├── frame_sign.c        # Main enclave: init keypair, sign loop
    │   ├── edge_wrapper.{c,h}  # Ocall wrappers (print, seed, frame, result)
    │   ├── compact_ed25519.{c,h}  # Ed25519 API (compact25519)
    │   ├── compact_wipe.{c,h}  # Secure memory wipe
    │   └── c25519/             # Ed25519 internals (public domain)
    │       ├── edsign.{c,h}    # Sign/verify
    │       ├── ed25519.{c,h}   # Point operations
    │       ├── f25519.{c,h}    # Field arithmetic GF(2^255-19)
    │       ├── fprime.{c,h}    # Scalar arithmetic mod l
    │       ├── sha512.{c,h}    # SHA-512 (used by Ed25519)
    │       └── c25519.{c,h}    # Curve25519 base
    │
    └── host/                   # Host runner (Linux, C++)
        ├── host.cpp            # Multi-threaded: capture thread + enclave
        ├── edge_wrapper.{cpp,h}  # Ocall dispatch (Keystone edge API)
```

---

## Quick Start

### Build & Test in Keystone QEMU

```bash
# Build full Keystone environment + frame-sign example
docker build -f Dockerfile.keystone -t tee-camera-keystone .

# Enter the container
docker run --rm -it tee-camera-keystone

# Inside container: boot QEMU
cd /keystone/build-generic64 && ./scripts/run-qemu.sh

# Inside QEMU:
insmod keystone-driver.ko
./frame-sign.ke
```

---

## Security Properties

- **Key isolation**: Ed25519 private key never leaves enclave memory (PMP-protected)
- **Attestation chain**: Keystone SM attestation proves enclave identity
- **Tamper evidence**: Hash binds signature to exact frame bytes
- **Replay prevention**: Monotonic sequence + rdcycle timestamp
- **Gap detection**: Missing sequence numbers reveal dropped/censored frames

---

## Hardware Target

**iCESugar Pro** (Lattice iCE40UP5K):
- 5280 LUTs, 128KB SPRAM, 1Mb BRAM
- Open toolchain (Yosys + nextpnr)
- PMOD camera interface

When the FPGA arrives, the capture thread replaces test frame generation with reads from the camera DMA buffer. The enclave signing code is identical.

---

## Crypto

Uses [compact25519](https://github.com/DavyLandman/compact25519) by Davy Landman, based on [Daniel Beer's c25519](https://www.dlbeer.co.nz/oss/c25519.html). Both public domain (CC0).

Designed for embedded/bare-metal: byte-level operations, no libc assumptions, no dynamic allocation. The full Ed25519 implementation is ~2000 lines across 12 files.

---

## License

MIT
