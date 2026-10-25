#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__clang__)
#define BARE __attribute__((no_sanitize("coverage")))
#else
#define BARE
#endif
#define BITMAP_PATH "/dev/shm/dst-coverage"
#define BITS (1u << 24)
#define BYTES (BITS / 8)
#define COVERAGE_PORT 0x5f0
#define PORT_PATH "/dev/port"

__thread uintptr_t __sancov_lowest_stack;

static uint8_t *bitmap;
static int lock_fd = -1;
static int port_fd = -1;
static int ready;
static uint32_t modules;
static uint8_t *counters_start;
static uint8_t *counters_stop;
static uint32_t counters_module;

BARE static uint32_t crc32_bytes(const uint8_t *bytes, size_t count) {
    uint32_t crc = 0xffffffffu;

    for (size_t index = 0; index < count; index++) {
        crc ^= bytes[index];

        for (int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
        }
    }

    return crc ^ 0xffffffffu;
}

BARE static int coverage_open(void) {
    const char *enabled = getenv("DST_COVERAGE");
    if (enabled == NULL || strcmp(enabled, "1") != 0) return 0;

    lock_fd = open(BITMAP_PATH, O_RDWR | O_CREAT, 0666);
    if (lock_fd < 0) return 0;
    if (ftruncate(lock_fd, BYTES) != 0) return 0;

    bitmap = mmap(NULL, BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, lock_fd, 0);
    if (bitmap == MAP_FAILED) return 0;

    port_fd = open(PORT_PATH, O_WRONLY);
    if (port_fd < 0) return 0;

    return 1;
}

BARE static void coverage_report(uint32_t module, uint32_t ordinal) {
    uint8_t key[8];
    uint32_t index;
    uint32_t offset;
    uint8_t mask;
    uint8_t encoded[3];

    memcpy(key, &module, 4);
    memcpy(key + 4, &ordinal, 4);
    index = crc32_bytes(key, 8) & (BITS - 1);
    offset = index / 8;
    mask = (uint8_t)(1u << (index % 8));
    if (bitmap[offset] & mask) return;

    flock(lock_fd, LOCK_EX);

    if ((bitmap[offset] & mask) == 0) {
        encoded[0] = (uint8_t)index;
        encoded[1] = (uint8_t)(index >> 8);
        encoded[2] = (uint8_t)(index >> 16);

        if (pwrite(port_fd, encoded, 3, COVERAGE_PORT) == 3) bitmap[offset] |= mask;
    }

    flock(lock_fd, LOCK_UN);
}

BARE void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    uint32_t ordinal = 1;

    if (start == stop || *start != 0) return;
    if (!ready) ready = coverage_open();

    modules++;

    for (uint32_t *guard = start; guard < stop; guard++) {
        *guard = ready ? ((modules << 24) | ordinal) : 0;
        ordinal++;
    }
}

BARE void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    uint32_t value = *guard;
    if (value == 0) return;

    *guard = 0;

    coverage_report(value >> 24, value & 0xffffffu);
}

BARE void __sanitizer_cov_8bit_counters_init(uint8_t *start, uint8_t *stop) {
    if (start == stop) return;
    if (!ready) ready = coverage_open();

    modules++;
    counters_start = start;
    counters_stop = stop;
    counters_module = modules;
}

BARE void __sanitizer_cov_pcs_init(const uintptr_t *start, const uintptr_t *stop) {
    (void)start;
    (void)stop;
}

BARE void __sanitizer_cov_trace_cmp1(uint8_t a, uint8_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_cmp2(uint16_t a, uint16_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_cmp4(uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_cmp8(uint64_t a, uint64_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_const_cmp1(uint8_t a, uint8_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_const_cmp2(uint16_t a, uint16_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_const_cmp4(uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_const_cmp8(uint64_t a, uint64_t b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_cov_trace_div4(uint32_t a) {
    (void)a;
}

BARE void __sanitizer_cov_trace_div8(uint64_t a) {
    (void)a;
}

BARE void __sanitizer_cov_trace_gep(uintptr_t a) {
    (void)a;
}

BARE void __sanitizer_cov_trace_pc_indir(uintptr_t a) {
    (void)a;
}

BARE void __sanitizer_cov_trace_switch(uint64_t a, uint64_t *b) {
    (void)a;
    (void)b;
}

BARE void __sanitizer_weak_hook_memcmp(void *a, const void *b, const void *c, size_t d, int e) {
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
}

BARE void __sanitizer_weak_hook_strcmp(void *a, const char *b, const char *c, int d) {
    (void)a;
    (void)b;
    (void)c;
    (void)d;
}

BARE void __sanitizer_weak_hook_strncmp(void *a, const char *b, const char *c, size_t d, int e) {
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
}

BARE void dst_coverage_scan(void) {
    if (!ready || counters_start == NULL) return;

    for (uint8_t *counter = counters_start; counter < counters_stop; counter++) {
        if (*counter == 0) continue;

        coverage_report(counters_module, (uint32_t)(counter - counters_start) + 1);
    }
}
