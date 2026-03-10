/*
 * keystone_wrapper.hpp – thin C interface over the Keystone C++ host SDK.
 *
 * This wrapper exists so Rust (and any other C-compatible language) can link
 * against the Keystone enclave API without needing C++ name mangling or the
 * cxx crate.
 */
#ifndef KEYSTONE_WRAPPER_HPP
#define KEYSTONE_WRAPPER_HPP

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle owning a Keystone::Enclave + Keystone::Params pair. */
typedef struct OpaqueKeystone OpaqueKeystone;

/*
 * Create and initialise a Keystone enclave.
 *   enclave_path   – path to the eapp binary
 *   runtime_path   – path to the Eyrie runtime
 *   free_mem_size  – bytes of free memory to allocate for the enclave
 *   untrusted_size – bytes to reserve for the untrusted shared-memory region
 *
 * Returns a non-NULL handle on success, NULL on failure.
 */
OpaqueKeystone *keystone_create(const char *enclave_path,
                                const char *runtime_path,
                                size_t      free_mem_size,
                                size_t      untrusted_size);

/* Destroy a handle returned by keystone_create. Safe to call with NULL. */
void keystone_destroy(OpaqueKeystone *h);

/*
 * Return the untrusted shared-memory buffer allocated for the enclave.
 * Returns NULL if h is NULL or the buffer is unavailable.
 */
void *keystone_get_shared_buffer(OpaqueKeystone *h);

/*
 * Run the enclave (blocks until the enclave exits).
 * Returns 0 on KEYSTONE_SUCCESS, non-zero otherwise.
 */
int keystone_run(OpaqueKeystone *h);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* KEYSTONE_WRAPPER_HPP */
