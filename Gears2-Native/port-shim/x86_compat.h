// macOS/arm64 stand-ins for the x86 intrinsics and the two Win32 wait primitives the ports use. Force-included into
// every translation unit of layer 0 (see templates/cmake_apple.cmake).
//
// Why force-include rather than editing the sources: the calls are spread over five files (observer_hub.cpp,
// shadow_renderer.cpp, pm4_shadow.cpp, d3d12_backend.cpp, system_report.cpp) and they are all timing or spin helpers.
// Defining them once here keeps the port's diff on the vendor code at zero for this particular problem.
//
// Correctness notes:
//  * The code does not assume a TSC frequency: TscMsPerTick() (d3d12_backend.cpp) calibrates the counter against
//    std::chrono::steady_clock at start-up, so any monotonic counter works. On Apple silicon clock_gettime_nsec_np is
//    a cheap read of the architected counter.
//  * WakeByAddressAll / WaitOnAddress are Win32's address-wait pair; here they map onto C++20 atomic wait/notify. The
//    objects passed in are already std::atomic, a spurious return is allowed by the Win32 contract, and the callers
//    re-check the value - so mapping "timed out" onto "woken" is safe.
#ifndef COGBOX_MAC_X86_COMPAT_H
#define COGBOX_MAC_X86_COMPAT_H

#if defined(__x86_64__) || defined(_M_X64) || defined(_M_IX86)
// A real x86 build: the compiler's own <intrin.h> and the Windows CRT provide all of this, nothing to do.
#else

#include <stdint.h>
#include <time.h>

static inline uint64_t __rdtsc(void) { return (uint64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// The x86 PAUSE hint's arm64 counterpart; clang accepts the yield instruction through inline asm.
static inline void _mm_pause(void) { __asm__ __volatile__("yield" ::: "memory"); }

#if defined(__cplusplus)
#include <atomic>
#include <chrono>

// No notify is needed: the waiter polls, so a wake is a no-op. The wait below is a bounded poll with the arm64 yield
// hint - slower than a futex, but correct, and it keeps this header usable from TUs that are not built as C++20.
template <class A>
static inline void WakeByAddressAll(A* /*addr*/) {}

template <class A, class V>
static inline bool WaitOnAddress(A* addr, V* expected, size_t /*size*/, uint32_t timeout_ms) {
  const V want = *expected;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (addr->load(std::memory_order_acquire) == want) {
    if (std::chrono::steady_clock::now() >= deadline) break;
    _mm_pause();
  }
  return true;
}
#endif  // __cplusplus

#endif  // x86

#endif  // COGBOX_MAC_X86_COMPAT_H
