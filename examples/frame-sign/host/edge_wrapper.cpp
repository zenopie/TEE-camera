#include "edge_wrapper.h"
#include <cstring>

#define OCALL_PRINT       1
#define OCALL_GET_SEED    2
#define OCALL_SEND_PUBKEY 3
#define OCALL_GET_FRAME   4
#define OCALL_SEND_RESULT 5

void
edge_init(Keystone::Enclave *enclave) {
    enclave->registerOcallDispatch(incoming_call_dispatch);
    register_call(OCALL_PRINT, print_wrapper);
    register_call(OCALL_GET_SEED, get_seed_wrapper);
    register_call(OCALL_SEND_PUBKEY, send_pubkey_wrapper);
    register_call(OCALL_GET_FRAME, get_frame_wrapper);
    register_call(OCALL_SEND_RESULT, send_result_wrapper);

    edge_call_init_internals(
        (uintptr_t)enclave->getSharedBuffer(),
        enclave->getSharedBufferSize());
}

void
print_wrapper(void *buffer) {
    struct edge_call *edge_call = (struct edge_call *)buffer;
    uintptr_t call_args;
    size_t arg_len;

    if (edge_call_args_ptr(edge_call, &call_args, &arg_len) != 0) {
        edge_call->return_data.call_status = CALL_STATUS_BAD_OFFSET;
        return;
    }

    handle_print((const char *)call_args);
    edge_call->return_data.call_status = CALL_STATUS_OK;
}

void
get_seed_wrapper(void *buffer) {
    struct edge_call *edge_call = (struct edge_call *)buffer;
    unsigned char seed[32];
    size_t len = 32;

    handle_get_seed(seed, &len);

    uintptr_t data_section = edge_call_data_ptr();
    memcpy((void *)data_section, seed, len);

    if (edge_call_setup_ret(edge_call, (void *)data_section, len)) {
        edge_call->return_data.call_status = CALL_STATUS_BAD_PTR;
    } else {
        edge_call->return_data.call_status = CALL_STATUS_OK;
    }
}

void
send_pubkey_wrapper(void *buffer) {
    struct edge_call *edge_call = (struct edge_call *)buffer;
    uintptr_t call_args;
    size_t arg_len;

    if (edge_call_args_ptr(edge_call, &call_args, &arg_len) != 0) {
        edge_call->return_data.call_status = CALL_STATUS_BAD_OFFSET;
        return;
    }

    handle_send_pubkey((const void *)call_args, arg_len);
    edge_call->return_data.call_status = CALL_STATUS_OK;
}

void
get_frame_wrapper(void *buffer) {
    struct edge_call *edge_call = (struct edge_call *)buffer;
    unsigned char frame_req[64];
    size_t len = sizeof(frame_req);

    handle_get_frame(frame_req, &len);

    uintptr_t data_section = edge_call_data_ptr();
    memcpy((void *)data_section, frame_req, len);

    if (edge_call_setup_ret(edge_call, (void *)data_section, len)) {
        edge_call->return_data.call_status = CALL_STATUS_BAD_PTR;
    } else {
        edge_call->return_data.call_status = CALL_STATUS_OK;
    }
}

void
send_result_wrapper(void *buffer) {
    struct edge_call *edge_call = (struct edge_call *)buffer;
    uintptr_t call_args;
    size_t arg_len;

    if (edge_call_args_ptr(edge_call, &call_args, &arg_len) != 0) {
        edge_call->return_data.call_status = CALL_STATUS_BAD_OFFSET;
        return;
    }

    handle_send_result((const void *)call_args, arg_len);
    edge_call->return_data.call_status = CALL_STATUS_OK;
}
