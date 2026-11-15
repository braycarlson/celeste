#include <stdint.h>
#include <stdio.h>

static uint64_t rdtsc(void) {
    uint32_t low;
    uint32_t high;

    __asm__ volatile("rdtsc" : "=a"(low), "=d"(high));

    return ((uint64_t)high << 32) | low;
}

static uint64_t rdtscp(uint32_t *aux) {
    uint32_t low;
    uint32_t high;

    __asm__ volatile("rdtscp" : "=a"(low), "=d"(high), "=c"(*aux));

    return ((uint64_t)high << 32) | low;
}

int main(void) {
    uint32_t aux = 0;
    uint64_t first = rdtsc();
    uint64_t second = rdtsc();
    uint64_t third = rdtscp(&aux);
    int increasing = first < second && second < third;

    printf(
        "TSC %llu %llu %llu aux=%u increasing=%d\n",
        (unsigned long long)first,
        (unsigned long long)second,
        (unsigned long long)third,
        aux,
        increasing
    );

    return 0;
}
