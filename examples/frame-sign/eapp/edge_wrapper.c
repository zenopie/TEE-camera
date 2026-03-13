#include "edge_wrapper.h"

#define OCALL_PRINT       1
#define OCALL_GET_SEED    2
#define OCALL_SEND_PUBKEY 3
#define OCALL_GET_FRAME   4
#define OCALL_SEND_RESULT 5

void ocall_print(const char *str) {
    size_t len = 0;
    while (str[len]) len++;
    ocall(OCALL_PRINT, (void *)str, len + 1, 0, 0);
}

void ocall_get_seed(void *buf, size_t len) {
    ocall(OCALL_GET_SEED, 0, 0, buf, len);
}

void ocall_send_pubkey(const void *data, size_t len) {
    ocall(OCALL_SEND_PUBKEY, (void *)data, len, 0, 0);
}

void ocall_get_frame(void *buf, size_t len) {
    ocall(OCALL_GET_FRAME, 0, 0, buf, len);
}

void ocall_send_result(const void *data, size_t len) {
    ocall(OCALL_SEND_RESULT, (void *)data, len, 0, 0);
}
