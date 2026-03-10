/*
 * keystone_wrapper.cpp – C-callable wrapper around the Keystone C++ host SDK.
 */

#include "keystone_wrapper.hpp"

/* Keystone C++ API (include path set by build.rs / Makefile). */
#include "keystone.h"

#include <new>      /* std::nothrow */
#include <cstdlib>  /* NULL         */

struct OpaqueKeystone {
    Keystone::Enclave enclave;
    Keystone::Params  params;
};

OpaqueKeystone *keystone_create(const char *enclave_path,
                                const char *runtime_path,
                                size_t      free_mem_size,
                                size_t      untrusted_size)
{
    OpaqueKeystone *h = new (std::nothrow) OpaqueKeystone();
    if (!h)
        return NULL;

    h->params.setFreeMemSize(free_mem_size);
    h->params.setUntrustedSize(untrusted_size);

    keystone_status_t rc = h->enclave.init(enclave_path, runtime_path, h->params);
    if (rc != KEYSTONE_SUCCESS) {
        delete h;
        return NULL;
    }

    return h;
}

void keystone_destroy(OpaqueKeystone *h)
{
    delete h; /* safe when h == NULL */
}

void *keystone_get_shared_buffer(OpaqueKeystone *h)
{
    if (!h)
        return NULL;
    return h->enclave.getSharedBuffer();
}

int keystone_run(OpaqueKeystone *h)
{
    if (!h)
        return -1;
    keystone_status_t rc = h->enclave.run();
    return (rc == KEYSTONE_SUCCESS) ? 0 : (int)rc;
}
