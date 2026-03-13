//******************************************************************************
// frame_sign.c - Frame signing enclave for TEE-camera
//
// The enclave drives the loop via ocalls:
//   1. Request seed from host -> derive Ed25519 keypair
//   2. Send public key to host
//   3. Loop: request frame hash -> sign -> send result
//   4. Exit when host signals CMD_EXIT
//******************************************************************************
#include "app/eapp_utils.h"
#include "app/syscall.h"
#include "edge_wrapper.h"
#include "compact_ed25519.h"
#include "../shared_mem.h"

#define SEED_SIZE      32
#define PUBKEY_SIZE    32
#define SECRETKEY_SIZE 64  /* Ed25519: seed(32) || pubkey(32) */
#define HASH_SIZE      32
#define MESSAGE_SIZE   48  /* hash(32) + seq(8) + ts(8) */

static uint8_t secret_key[SECRETKEY_SIZE];
static uint8_t public_key[PUBKEY_SIZE];
static uint64_t frame_sequence = 0;

static inline uint64_t get_timestamp(void) {
    uint64_t cycles;
    asm volatile("rdcycle %0" : "=r"(cycles));
    return cycles;
}

void EAPP_ENTRY eapp_entry() {
    uint8_t seed[SEED_SIZE];
    FrameRequest req;
    SignatureResult result;
    uint8_t message[MESSAGE_SIZE];
    int i;

    ocall_print("[enclave] started\n");

    /* Step 1: Get seed from host */
    ocall_get_seed(seed, SEED_SIZE);
    ocall_print("[enclave] got seed\n");

    /* Step 2: Derive Ed25519 keypair */
    compact_ed25519_keygen(secret_key, public_key, seed);

    /* Step 3: Send public key to host */
    ocall_send_pubkey(public_key, PUBKEY_SIZE);
    ocall_print("[enclave] Ed25519 keypair initialized\n");

    /* Step 4: Frame signing loop (runs forever, host manages lifecycle) */
    while (1) {
        ocall_get_frame(&req, sizeof(req));

        if (req.cmd != CMD_SIGN)
            continue;

        result.timestamp = get_timestamp();
        result.sequence = frame_sequence;

        /* Build message: hash || sequence || timestamp */
        for (i = 0; i < HASH_SIZE; i++)
            message[i] = req.hash[i];
        for (i = 0; i < 8; i++)
            message[32 + i] = ((uint8_t *)&result.sequence)[i];
        for (i = 0; i < 8; i++)
            message[40 + i] = ((uint8_t *)&result.timestamp)[i];

        /* Sign with Ed25519 */
        compact_ed25519_sign(result.signature, secret_key,
                            message, MESSAGE_SIZE);
        frame_sequence++;

        ocall_send_result(&result, sizeof(result));
    }
}
