// Camera attestation firmware: PUF → Ed25519 keypair → sign frame hashes
// Signature data written to IO registers for HDMI barcode output.
#include "hw.h"
#include "monocypher-ed25519.h"

static void delay(int n) {
    for (volatile int i = 0; i < n; i++) ;
}

void main(void) {
    delay(50000);  // let DAPLink settle

    // ── Phase 1: Wait for PUF and derive Ed25519 keypair ──
    while (!(REG_STATUS & STATUS_PUF_DONE)) ;

    // Read 128-bit PUF output as seed material
    uint8_t puf_raw[16];
    for (int i = 0; i < 4; i++) {
        uint32_t w = REG_PUF(i);
        puf_raw[i*4+0] = (w >>  0) & 0xFF;
        puf_raw[i*4+1] = (w >>  8) & 0xFF;
        puf_raw[i*4+2] = (w >> 16) & 0xFF;
        puf_raw[i*4+3] = (w >> 24) & 0xFF;
    }

    // Expand 128-bit PUF to 32-byte seed via SHA-512 (take first 32 bytes)
    uint8_t seed[32];
    {
        uint8_t hash[64];
        crypto_sha512(hash, puf_raw, 16);
        for (int i = 0; i < 32; i++) seed[i] = hash[i];
        crypto_wipe(hash, 64);
    }
    crypto_wipe(puf_raw, 16);

    // Derive Ed25519 keypair
    uint8_t sk[64], pk[32];
    crypto_ed25519_key_pair(sk, pk, seed);

    // Write public key to HDMI signature registers (offset 0, 32 bytes)
    sig_write(pk, 0, 32);

    // ── Phase 2: Sign frame hashes in a loop ──
    while (1) {
        // Wait for a new frame hash from the hardware hasher
        while (!(REG_STATUS & STATUS_HASH_VALID)) ;

        uint32_t frame_num = REG_FRAME_COUNT;

        // Read 512-bit frame hash (16 × 32-bit words)
        uint8_t frame_hash[64];
        for (int i = 0; i < 16; i++) {
            uint32_t w = REG_HASH(i);
            frame_hash[i*4+0] = (w >>  0) & 0xFF;
            frame_hash[i*4+1] = (w >>  8) & 0xFF;
            frame_hash[i*4+2] = (w >> 16) & 0xFF;
            frame_hash[i*4+3] = (w >> 24) & 0xFF;
        }

        // Acknowledge hash (clears hash_valid_latch so hasher can produce next)
        REG_CONTROL = CTRL_ACK_HASH;

        // Build the message to sign: frame_num (4B BE) || hash[0..60]
        uint8_t msg[64];
        msg[0] = (frame_num >> 24) & 0xFF;
        msg[1] = (frame_num >> 16) & 0xFF;
        msg[2] = (frame_num >>  8) & 0xFF;
        msg[3] = (frame_num >>  0) & 0xFF;
        for (int i = 0; i < 60; i++) msg[4+i] = frame_hash[i];

        // Sign
        REG_CONTROL = CTRL_SET_SIGNING;
        uint8_t sig[64];
        crypto_ed25519_sign(sig, sk, msg, 64);
        REG_CONTROL = CTRL_CLR_SIGNING;

        // Write attestation data to HDMI signature registers
        // Layout: pubkey(32) + frame_num(4) + hash(64) + sig(64)
        uint8_t fn_be[4] = {
            (frame_num >> 24) & 0xFF,
            (frame_num >> 16) & 0xFF,
            (frame_num >>  8) & 0xFF,
            (frame_num >>  0) & 0xFF
        };
        sig_write(fn_be, 32, 4);
        sig_write(frame_hash, 36, 64);
        sig_write(sig, 100, 64);
    }
}
