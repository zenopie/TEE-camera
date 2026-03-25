// Minimal libgcc helpers for 64-bit ops on RV32
// Also provides bare-metal libc shims (memcpy, memset)
#include <stdint.h>
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = dst; const uint8_t *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *s, int c, size_t n) {
    uint8_t *p = s;
    while (n--) *p++ = c;
    return s;
}

int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *pa = a, *pb = b;
    while (n--) {
        if (*pa != *pb) return *pa - *pb;
        pa++; pb++;
    }
    return 0;
}

typedef union { uint64_t u64; struct { uint32_t lo, hi; }; } du;

uint64_t __lshrdi3(uint64_t a, int b) {
    du x = { .u64 = a };
    if (b >= 32) { x.lo = x.hi >> (b - 32); x.hi = 0; }
    else if (b) { x.lo = (x.lo >> b) | (x.hi << (32 - b)); x.hi >>= b; }
    return x.u64;
}

uint64_t __ashldi3(uint64_t a, int b) {
    du x = { .u64 = a };
    if (b >= 32) { x.hi = x.lo << (b - 32); x.lo = 0; }
    else if (b) { x.hi = (x.hi << b) | (x.lo >> (32 - b)); x.lo <<= b; }
    return x.u64;
}

uint64_t __ashrdi3(uint64_t a, int b) {
    du x = { .u64 = a };
    if (b >= 32) { x.lo = (int32_t)x.hi >> (b - 32); x.hi = (int32_t)x.hi >> 31; }
    else if (b) { x.lo = (x.lo >> b) | (x.hi << (32 - b)); x.hi = (int32_t)x.hi >> b; }
    return x.u64;
}
