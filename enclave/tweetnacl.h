#pragma once
/*
 * TweetNaCl - Public domain crypto library
 * Ed25519 signatures via crypto_sign / crypto_sign_open.
 *
 * This header exposes the Ed25519 signing interface plus a seed-based
 * keypair derivation helper used by the enclave.
 */

#include <stdint.h>
#include <stddef.h>

/* ---------------------------------------------------------------------------
 * Low-level type aliases used internally
 * -------------------------------------------------------------------------*/
typedef uint8_t  u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t  i64;
typedef int64_t  gf[16];

/* ---------------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------------*/

/*
 * crypto_sign_keypair
 *   Generate a random Ed25519 keypair.
 *   pk : 32-byte public key output
 *   sk : 64-byte secret key output (seed || pk)
 *   Returns 0 on success.
 *
 *   NOTE: This version uses an internal PRNG seeded from a global state.
 *   Prefer crypto_sign_keypair_from_seed for deterministic key derivation.
 */
int crypto_sign_keypair(uint8_t *pk, uint8_t *sk);

/*
 * crypto_sign_keypair_from_seed
 *   Derive a deterministic Ed25519 keypair from a 32-byte seed.
 *   pk   : 32-byte public key output
 *   sk   : 64-byte secret key output (seed || pk)
 *   seed : 32-byte input seed
 *   Returns 0 on success.
 */
int crypto_sign_keypair_from_seed(uint8_t *pk, uint8_t *sk,
                                  const uint8_t *seed);

/*
 * crypto_sign
 *   Sign a message using Ed25519.
 *   sm    : output buffer (m_len + 64 bytes)
 *   smlen : output: length of signed message
 *   m     : input message
 *   mlen  : input message length
 *   sk    : 64-byte secret key
 *   Returns 0 on success.
 */
int crypto_sign(uint8_t *sm, uint64_t *smlen,
                const uint8_t *m, uint64_t mlen,
                const uint8_t *sk);

/*
 * crypto_sign_open
 *   Verify and open a signed message.
 *   m    : output buffer (at least smlen bytes)
 *   mlen : output: length of recovered message
 *   sm   : signed message
 *   smlen: length of signed message
 *   pk   : 32-byte public key
 *   Returns 0 on success, -1 on verification failure.
 */
int crypto_sign_open(uint8_t *m, uint64_t *mlen,
                     const uint8_t *sm, uint64_t smlen,
                     const uint8_t *pk);

/* Sizes */
#define CRYPTO_SIGN_BYTES     64
#define CRYPTO_SIGN_PUBLICKEYBYTES  32
#define CRYPTO_SIGN_SECRETKEYBYTES  64
#define CRYPTO_SIGN_SEEDBYTES       32
