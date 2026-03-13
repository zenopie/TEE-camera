//******************************************************************************
// host.cpp - Multi-threaded host runner for frame signing enclave
//
// Two threads:
//   - Capture thread: generates frame hashes, pushes to queue
//   - Main thread: runs enclave, ocall handlers pull from queue
//
// The enclave loops forever; host destroys it when capture is done.
//******************************************************************************
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include "edge_wrapper.h"
#include "host/keystone.h"
#include "../shared_mem.h"

#define HASH_SIZE       32
#define QUEUE_CAPACITY  16
#define NUM_TEST_FRAMES 10

/* ---- Thread-safe frame queue ---- */

struct FrameQueue {
    FrameRequest slots[QUEUE_CAPACITY];
    int head, tail, count;
    bool done;  /* capture thread sets when finished */
    pthread_mutex_t mtx;
    pthread_cond_t  not_empty;
    pthread_cond_t  not_full;
};

static FrameQueue queue;
static unsigned char stored_pubkey[ED25519_PK_BYTES];
static int frames_signed = 0;
static bool queue_drained = false;

static void queue_init(FrameQueue *q) {
    q->head = q->tail = q->count = 0;
    q->done = false;
    pthread_mutex_init(&q->mtx, NULL);
    pthread_cond_init(&q->not_empty, NULL);
    pthread_cond_init(&q->not_full, NULL);
}

static void queue_push(FrameQueue *q, const FrameRequest *fr) {
    pthread_mutex_lock(&q->mtx);
    while (q->count == QUEUE_CAPACITY)
        pthread_cond_wait(&q->not_full, &q->mtx);
    q->slots[q->tail] = *fr;
    q->tail = (q->tail + 1) % QUEUE_CAPACITY;
    q->count++;
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mtx);
}

/* Returns false if queue is empty AND capture is done */
static bool queue_pop(FrameQueue *q, FrameRequest *fr) {
    pthread_mutex_lock(&q->mtx);
    while (q->count == 0 && !q->done)
        pthread_cond_wait(&q->not_empty, &q->mtx);
    if (q->count == 0 && q->done) {
        pthread_mutex_unlock(&q->mtx);
        return false;
    }
    *fr = q->slots[q->head];
    q->head = (q->head + 1) % QUEUE_CAPACITY;
    q->count--;
    pthread_cond_signal(&q->not_full);
    pthread_mutex_unlock(&q->mtx);
    return true;
}

static void queue_mark_done(FrameQueue *q) {
    pthread_mutex_lock(&q->mtx);
    q->done = true;
    pthread_cond_broadcast(&q->not_empty);
    pthread_mutex_unlock(&q->mtx);
}

/* ---- Helpers ---- */

static void print_hex(const char *label, const unsigned char *data, size_t len) {
    printf("%s: ", label);
    for (size_t i = 0; i < len && i < 16; i++) printf("%02x", data[i]);
    if (len > 16) printf("...");
    printf("\n");
}

static void test_hash(int frame_num, unsigned char *out) {
    memset(out, 0, HASH_SIZE);
    out[0] = (frame_num >> 0) & 0xFF;
    out[1] = (frame_num >> 8) & 0xFF;
    out[2] = (frame_num >> 16) & 0xFF;
    out[3] = (frame_num >> 24) & 0xFF;
    for (int i = 4; i < HASH_SIZE; i++)
        out[i] = (unsigned char)((frame_num + i) & 0xFF);
}

/* ---- Capture thread ---- */

static void *capture_thread(void *arg) {
    int total = *(int *)arg;
    printf("[capture] Starting capture (%d frames)\n", total);

    for (int i = 0; i < total; i++) {
        FrameRequest req;
        req.cmd = CMD_SIGN;
        test_hash(i, req.hash);
        queue_push(&queue, &req);
        printf("[capture] Queued frame %d/%d\n", i + 1, total);
    }

    queue_mark_done(&queue);
    printf("[capture] All frames queued, capture done\n");
    return NULL;
}

/* ---- Ocall handlers (called from edge dispatch) ---- */

void handle_print(const char *str) {
    printf("%s", str);
}

void handle_get_seed(void *buf, size_t *len) {
    printf("[host] Providing seed to enclave\n");
    unsigned char seed[32] = {
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60,
        0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0x44,
        0xd2, 0x23, 0x77, 0x45, 0x29, 0xe0, 0x27, 0x7f,
        0x44, 0x3a, 0x2c, 0xa5, 0x53, 0x96, 0x67, 0x03
    };
    memcpy(buf, seed, 32);
    *len = 32;
}

void handle_send_pubkey(const void *data, size_t len) {
    size_t copy = len < 32 ? len : 32;
    memcpy(stored_pubkey, data, copy);
    print_hex("[host] Public key", stored_pubkey, 32);
}

void handle_get_frame(void *buf, size_t *len) {
    FrameRequest *req = (FrameRequest *)buf;

    if (!queue_pop(&queue, req)) {
        /* Queue drained and capture done — signal to stop enclave */
        queue_drained = true;
        memset(req, 0, sizeof(FrameRequest));
    }

    *len = sizeof(FrameRequest);
}

void handle_send_result(const void *data, size_t len) {
    const SignatureResult *res = (const SignatureResult *)data;
    printf("[host] Frame %llu signed (ts=%llu)\n",
           (unsigned long long)res->sequence,
           (unsigned long long)res->timestamp);
    print_hex("[host]   sig", res->signature, ED25519_SIG_BYTES);
    frames_signed++;
}

/* ---- Main ---- */

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <eapp> <runtime> <loader>\n", argv[0]);
        return 1;
    }

    queue_init(&queue);
    int total_frames = NUM_TEST_FRAMES;

    /* Start capture thread */
    pthread_t cap_tid;
    pthread_create(&cap_tid, NULL, capture_thread, &total_frames);

    /* Init enclave */
    Keystone::Enclave enclave;
    Keystone::Params params;
    params.setFreeMemSize(48 * 1024 * 1024);
    params.setUntrustedSize(2 * 1024 * 1024);

    printf("[host] Initializing enclave...\n");
    if (enclave.init(argv[1], argv[2], argv[3], params) != Keystone::Error::Success) {
        fprintf(stderr, "[host] ERROR: Failed to init enclave\n");
        return 1;
    }

    edge_init(&enclave);

    printf("[host] Running enclave...\n");

    /* Run the enclave. It loops forever via ocalls.
     * When the queue drains, handle_get_frame sets queue_drained
     * and we break out to destroy the enclave. */
    while (!queue_drained) {
        uintptr_t ret = 0;
        enclave.run(&ret);
    }

    /* Wait for capture thread */
    pthread_join(cap_tid, NULL);

    printf("\n[host] Enclave stopped\n");
    printf("[host] Frames signed: %d/%d\n", frames_signed, total_frames);

    if (frames_signed >= total_frames) {
        printf("\n[host] === ALL TESTS PASSED ===\n");
        return 0;
    } else {
        printf("\n[host] === TESTS FAILED ===\n");
        return 1;
    }
}
