#ifndef _EDGE_WRAPPER_H_
#define _EDGE_WRAPPER_H_

#include "app/syscall.h"
#include "edge/edge_common.h"

void ocall_print(const char *str);
void ocall_get_seed(void *buf, size_t len);
void ocall_send_pubkey(const void *data, size_t len);
void ocall_get_frame(void *buf, size_t len);
void ocall_send_result(const void *data, size_t len);

#endif /* _EDGE_WRAPPER_H_ */
