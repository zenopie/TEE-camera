#ifndef _EDGE_WRAPPER_H_
#define _EDGE_WRAPPER_H_

#include "edge/edge_call.h"
#include "host/keystone.h"

void edge_init(Keystone::Enclave *enclave);

/* Dispatch wrappers */
void print_wrapper(void *buffer);
void get_seed_wrapper(void *buffer);
void send_pubkey_wrapper(void *buffer);
void get_frame_wrapper(void *buffer);
void send_result_wrapper(void *buffer);

/* Callbacks implemented in host.cpp */
void handle_print(const char *str);
void handle_get_seed(void *buf, size_t *len);
void handle_send_pubkey(const void *data, size_t len);
void handle_get_frame(void *buf, size_t *len);
void handle_send_result(const void *data, size_t len);

#endif /* _EDGE_WRAPPER_H_ */
