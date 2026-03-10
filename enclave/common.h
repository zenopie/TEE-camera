#pragma once
#include <stdint.h>
#include <stddef.h>

#define FRAME_MAX_BYTES  (1920 * 1080 * 3)  /* max raw RGB frame */
#define ED25519_SIG_BYTES 64
#define ED25519_PK_BYTES  32
#define SHA256_BYTES      32

typedef struct {
    uint64_t sequence;       /* monotonically increasing frame counter */
    uint64_t monotonic_ts;   /* monotonic counter from SM (or cycle counter fallback) */
    uint8_t  frame_hash[SHA256_BYTES];
    uint8_t  sig[ED25519_SIG_BYTES];
    uint8_t  pubkey[ED25519_PK_BYTES];
    uint32_t width;
    uint32_t height;
    uint32_t format;         /* 0=raw_rgb, 1=raw_gray, 2=synthetic */
    uint32_t frame_size;     /* actual bytes in this frame */
} SignedFrame;

/* Shared memory layout between host and enclave */
typedef struct {
    uint32_t cmd;            /* 0=nop, 1=sign_frame, 2=get_pubkey */
    uint32_t status;         /* 0=idle, 1=busy, 2=done, 3=error */
    uint32_t frame_size;
    uint32_t width;
    uint32_t height;
    uint32_t format;
    SignedFrame result;
    uint8_t  frame_data[FRAME_MAX_BYTES];
} SharedMem;

#define CMD_NOP       0
#define CMD_SIGN      1
#define CMD_GET_PK    2
#define STATUS_IDLE   0
#define STATUS_BUSY   1
#define STATUS_DONE   2
#define STATUS_ERROR  3
