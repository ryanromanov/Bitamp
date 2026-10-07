#ifndef BITAMP_ATOMICS_H
#define BITAMP_ATOMICS_H

#include <stdint.h>

/// Acquire and release loads and stores, for handing data to the audio render thread
/// without locks. Swift on macOS 13 has no atomics of its own.

static inline int32_t bitamp_load_acquire_32(const int32_t *address) {
    return __atomic_load_n(address, __ATOMIC_ACQUIRE);
}

static inline void bitamp_store_release_32(int32_t *address, int32_t value) {
    __atomic_store_n(address, value, __ATOMIC_RELEASE);
}

static inline int64_t bitamp_load_acquire_64(const int64_t *address) {
    return __atomic_load_n(address, __ATOMIC_ACQUIRE);
}

static inline void bitamp_store_release_64(int64_t *address, int64_t value) {
    __atomic_store_n(address, value, __ATOMIC_RELEASE);
}

#endif
