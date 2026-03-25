// Hardware register interface for camera attestation SoC
#ifndef HW_H
#define HW_H

#include <stdint.h>

#define IO_BASE      0x80000000

#define REG_STATUS   (*(volatile uint32_t *)(IO_BASE + 0x00))
#define REG_CONTROL  (*(volatile uint32_t *)(IO_BASE + 0x04))

// PUF bits (128-bit, 4 words)
#define REG_PUF(i)   (*(volatile uint32_t *)(IO_BASE + 0x08 + (i)*4))

// Frame hash (512-bit, 16 words)
#define REG_HASH(i)  (*(volatile uint32_t *)(IO_BASE + 0x20 + (i)*4))

// UART
#define REG_UART_TX  (*(volatile uint32_t *)(IO_BASE + 0x60))
#define REG_UART_BUSY (*(volatile uint32_t *)(IO_BASE + 0x64))

// Frame count
#define REG_FRAME_COUNT (*(volatile uint32_t *)(IO_BASE + 0x68))

// Signature data register file (written by CPU, read by HDMI barcode)
// Layout: pubkey(32) + frame_num(4) + hash(64) + sig(64) = 164 bytes
#define REG_SIG_BASE    (IO_BASE + 0x80)
#define REG_SIG(i)      (*(volatile uint32_t *)(REG_SIG_BASE + (i)*4))

static inline void sig_write(const uint8_t *buf, int offset, int len) {
    for (int i = 0; i < len; i += 4) {
        uint32_t w = (uint32_t)buf[i]
                   | ((uint32_t)buf[i+1] << 8)
                   | ((uint32_t)buf[i+2] << 16)
                   | ((uint32_t)buf[i+3] << 24);
        *(volatile uint32_t *)(REG_SIG_BASE + offset + i) = w;
    }
}

// Status bits
#define STATUS_PUF_DONE    (1 << 0)
#define STATUS_HASH_VALID  (1 << 1)
#define STATUS_SIGNING     (1 << 2)

// Control bits
#define CTRL_ACK_HASH      (1 << 1)
#define CTRL_SET_SIGNING   (1 << 2)
#define CTRL_CLR_SIGNING   (1 << 3)

static inline void uart_putc(uint8_t c) {
    while (REG_UART_BUSY) ;
    REG_UART_TX = c;
}

static inline void uart_send(const uint8_t *buf, int len) {
    for (int i = 0; i < len; i++)
        uart_putc(buf[i]);
}

#endif
