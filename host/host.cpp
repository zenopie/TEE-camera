/*
 * host.cpp - Keystone enclave host runner for TEE-camera frame signing.
 *
 * Build: see Makefile
 * Usage:
 *   host --enclave <eapp.eapp> --runtime <eyrie-rt> \
 *        --frames <count> --width <w> --height <h> \
 *        --fps <fps> --output <dir>
 *
 * The host:
 *  1. Loads and starts the Keystone enclave.
 *  2. Obtains the untrusted shared-memory region (SharedMem).
 *  3. Iterates over <count> synthetic frames, writes each into shm->frame_data,
 *     sets the control fields, issues CMD_SIGN, then spin-waits for STATUS_DONE.
 *  4. Writes each SignedFrame as a binary file: <output>/frame_NNNNNN.sig
 *  5. Prints a summary when finished.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <ctime>
#include <cinttypes>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <climits>

/* Keystone host SDK */
#include "keystone/sdk/include/host/keystone.h"

/* Shared types with the enclave */
#include "../enclave/common.h"

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s --enclave <path> --runtime <path>\n"
        "          --frames <count> --width <w> --height <h>\n"
        "          --fps <fps> --output <dir>\n",
        prog);
}

/* Return current time in seconds as a double. */
static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Sleep until the next frame deadline. */
static void sleep_until(double deadline)
{
    double remaining = deadline - now_sec();
    if (remaining <= 0.0)
        return;
    struct timespec ts;
    ts.tv_sec  = (time_t)remaining;
    ts.tv_nsec = (long)((remaining - (double)ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
}

/* Ensure output directory exists. */
static int ensure_dir(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0) {
        if (S_ISDIR(st.st_mode))
            return 0;
        fprintf(stderr, "Error: '%s' exists but is not a directory\n", path);
        return -1;
    }
    if (mkdir(path, 0755) != 0) {
        fprintf(stderr, "Error: cannot create directory '%s': %s\n",
                path, strerror(errno));
        return -1;
    }
    return 0;
}

/* Generate synthetic frame N: byte at position i is (i + N) % 256. */
static void generate_frame(uint8_t *buf, size_t len, uint64_t frame_n)
{
    for (size_t i = 0; i < len; i++) {
        buf[i] = (uint8_t)((i + (size_t)frame_n) & 0xFF);
    }
}

/* Write a SignedFrame struct to <output_dir>/frame_NNNNNN.sig */
static int write_signed_frame(const char *output_dir,
                              uint64_t seq,
                              const SignedFrame *sf)
{
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/frame_%06" PRIu64 ".sig",
             output_dir, seq);

    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "Error: cannot open '%s' for writing: %s\n",
                path, strerror(errno));
        return -1;
    }

    size_t written = fwrite(sf, sizeof(SignedFrame), 1, f);
    fclose(f);

    if (written != 1) {
        fprintf(stderr, "Error: short write to '%s'\n", path);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                                 */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    /* ---- Parse arguments ---- */
    const char *enclave_path = NULL;
    const char *runtime_path = NULL;
    const char *output_dir   = NULL;
    long        frames       = 1;
    long        width        = 640;
    long        height       = 480;
    long        fps          = 30;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--enclave") == 0 && i + 1 < argc) {
            enclave_path = argv[++i];
        } else if (strcmp(argv[i], "--runtime") == 0 && i + 1 < argc) {
            runtime_path = argv[++i];
        } else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
            frames = atol(argv[++i]);
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            width = atol(argv[++i]);
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            height = atol(argv[++i]);
        } else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
            fps = atol(argv[++i]);
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_dir = argv[++i];
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!enclave_path || !runtime_path || !output_dir) {
        usage(argv[0]);
        return 1;
    }

    if (frames <= 0 || width <= 0 || height <= 0 || fps <= 0) {
        fprintf(stderr, "Error: frames, width, height, fps must be positive\n");
        return 1;
    }

    uint32_t frame_width  = (uint32_t)width;
    uint32_t frame_height = (uint32_t)height;
    uint32_t frame_size   = frame_width * frame_height * 3; /* RGB */

    if (frame_size > FRAME_MAX_BYTES) {
        fprintf(stderr,
            "Error: frame size %u exceeds FRAME_MAX_BYTES (%u)\n",
            frame_size, (uint32_t)FRAME_MAX_BYTES);
        return 1;
    }

    if (ensure_dir(output_dir) != 0)
        return 1;

    /* ---- Configure and start enclave ---- */
    Keystone::Enclave enclave;
    Keystone::Params  params;

    /*
     * The untrusted shared region must hold at least one SharedMem struct.
     * Round up to the next 4 KB page boundary.
     */
    size_t shm_size = sizeof(SharedMem);
    size_t shm_pages = (shm_size + 4095UL) / 4096UL;
    if (shm_pages == 0) shm_pages = 1;

    /* Give the enclave 16 MB of free memory for stack/heap. */
    params.setFreeMemSize(16 * 1024 * 1024UL);
    params.setUntrustedSize(shm_pages * 4096UL);

    keystone_status_t rc = enclave.init(enclave_path, runtime_path, params);
    if (rc != KEYSTONE_SUCCESS) {
        fprintf(stderr, "Error: enclave.init failed (status %d)\n", (int)rc);
        return 1;
    }

    /* Obtain the shared memory buffer. */
    void *shm_raw = enclave.getSharedBuffer();
    if (!shm_raw) {
        fprintf(stderr, "Error: getSharedBuffer returned NULL\n");
        return 1;
    }
    SharedMem *shm = reinterpret_cast<SharedMem *>(shm_raw);

    /* Initialise the shared region. */
    memset(shm, 0, sizeof(SharedMem));
    shm->cmd    = CMD_NOP;
    shm->status = STATUS_IDLE;

    /*
     * Run the enclave in a background thread via Keystone's non-blocking
     * run if available, or just call enclave.run() which blocks until the
     * enclave exits.  Because the enclave loops waiting for CMD_SIGN,
     * we spawn it in a separate thread so the host can drive it.
     */
    pthread_t enclave_thread;
    struct EnclaveRunArg {
        Keystone::Enclave *enc;
        keystone_status_t  status;
    } run_arg = { &enclave, KEYSTONE_SUCCESS };

    auto enclave_thread_fn = [](void *arg) -> void * {
        EnclaveRunArg *a = reinterpret_cast<EnclaveRunArg *>(arg);
        a->status = a->enc->run();
        return NULL;
    };

    if (pthread_create(&enclave_thread, NULL,
                       enclave_thread_fn, &run_arg) != 0) {
        fprintf(stderr, "Error: pthread_create for enclave thread failed: %s\n",
                strerror(errno));
        return 1;
    }

    /* Brief spin to let the enclave reach its idle loop. */
    {
        int waited = 0;
        while (shm->status != STATUS_IDLE && waited < 5000) {
            usleep(1000);
            waited++;
        }
    }

    /* ---- Frame loop ---- */
    double frame_interval = (fps > 0) ? (1.0 / (double)fps) : 0.0;
    double start_time     = now_sec();
    double next_deadline  = start_time;

    long errors = 0;

    for (long n = 0; n < frames; n++) {
        next_deadline += frame_interval;

        /* Generate synthetic frame data directly into shared memory. */
        generate_frame(shm->frame_data, frame_size, (uint64_t)n);

        /* Set control metadata. */
        shm->frame_size = frame_size;
        shm->width      = frame_width;
        shm->height     = frame_height;
        shm->format     = 2; /* synthetic */
        shm->status     = STATUS_IDLE;

        /* Memory barrier before issuing the command. */
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        shm->cmd = CMD_SIGN;
        __atomic_thread_fence(__ATOMIC_SEQ_CST);

        /* Spin-wait for the enclave to finish signing. */
        uint32_t status;
        do {
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            status = shm->status;
        } while (status == STATUS_IDLE || status == STATUS_BUSY);

        if (status == STATUS_ERROR) {
            fprintf(stderr,
                "Frame %ld: enclave returned STATUS_ERROR\n", n);
            errors++;
            shm->cmd    = CMD_NOP;
            shm->status = STATUS_IDLE;
            continue;
        }

        /* STATUS_DONE: copy the SignedFrame out. */
        SignedFrame sf;
        memcpy(&sf, &shm->result, sizeof(SignedFrame));

        /* Reset command field. */
        shm->cmd    = CMD_NOP;
        shm->status = STATUS_IDLE;

        /* Write to disk. */
        if (write_signed_frame(output_dir, (uint64_t)n, &sf) != 0) {
            errors++;
        }

        /* Rate-limit to requested FPS. */
        if (fps > 0)
            sleep_until(next_deadline);

        if ((n + 1) % 100 == 0 || n == frames - 1) {
            fprintf(stdout, "Processed %ld / %ld frames\r", n + 1, frames);
            fflush(stdout);
        }
    }

    /* Signal enclave to exit: we rely on the enclave checking for a
     * sentinel or simply waiting; here we send CMD_NOP so it can exit
     * its loop on the next iteration.  The enclave is expected to exit
     * cleanly when the host tears down shared memory, or after receiving
     * a NOP following completion. */
    shm->cmd = CMD_NOP;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);

    /* Wait for the enclave thread to finish. */
    pthread_join(enclave_thread, NULL);

    /* ---- Summary ---- */
    double elapsed  = now_sec() - start_time;
    double achieved = (elapsed > 0.0) ? ((double)frames / elapsed) : 0.0;

    printf("\n=== Summary ===\n");
    printf("  Frames requested : %ld\n", frames);
    printf("  Frames processed : %ld\n", frames - errors);
    printf("  Errors           : %ld\n", errors);
    printf("  Elapsed          : %.3f s\n", elapsed);
    printf("  FPS achieved     : %.2f\n", achieved);
    printf("  Output directory : %s\n", output_dir);

    return (errors == 0) ? 0 : 1;
}
