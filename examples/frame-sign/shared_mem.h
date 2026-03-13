#ifndef _SHARED_MEM_H_
#define _SHARED_MEM_H_

#include <stdint.h>
#include <stddef.h>

#define ED25519_SIG_BYTES  64
#define ED25519_PK_BYTES   32
#define SHA256_BYTES       32

/* Commands sent from host to enclave via frame request */
#define CMD_SIGN  1

/* Frame request: host -> enclave (via ocall return) */
typedef struct __attribute__((packed)) {
    uint8_t  cmd;
    uint8_t  hash[SHA256_BYTES];
} FrameRequest;

/* Signature result: enclave -> host (via ocall) */
typedef struct __attribute__((packed)) {
    uint8_t  signature[ED25519_SIG_BYTES];
    uint64_t sequence;
    uint64_t timestamp;
} SignatureResult;

/* Signed frame header for output/verification */
#define SIGNED_FRAME_MAGIC 0x5347464D  /* "SGFM" */
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint32_t header_size;
    uint64_t sequence;
    uint64_t monotonic_ts;
    uint8_t  frame_hash[SHA256_BYTES];
    uint8_t  sig[ED25519_SIG_BYTES];
    uint8_t  pubkey[ED25519_PK_BYTES];
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint32_t frame_size;
} SignedFrameHeader;

#endif /* _SHARED_MEM_H_ */
