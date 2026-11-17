// Win32 structured-exception / VirtualQuery stand-ins for the macOS build of
// Gears3-Native's layer 2 (objects.cpp, config_install.cpp).
//
// These two files scan guest memory for UE3 object tables. On Windows they use SEH
// (__try/__except) plus VirtualQuery to skip uncommitted/guarded pages. macOS has
// neither, so:
//   * __try / __except become an always-true if / never-taken else - the bodies still
//     compile and run, but a faulting read is no longer caught;
//   * VirtualQuery reports no region, so the region scan is skipped. That is a
//     diagnostic/table-search path, not the startup path.
// Force-included only into gn_layer2_ue3 by port/tools/patch_cogbox_macos.py.
#ifndef COGBOX_MAC_WIN32_SEH_H
#define COGBOX_MAC_WIN32_SEH_H

#ifndef _WIN32

#include <cstddef>
#include <cstdint>

typedef struct _COGBOX_MEMORY_BASIC_INFORMATION {
  void* BaseAddress;
  size_t RegionSize;
  unsigned long State;
  unsigned long Protect;
} MEMORY_BASIC_INFORMATION;

#define MEM_COMMIT 0x1000ul
#define PAGE_NOACCESS 0x01ul
#define PAGE_GUARD 0x02ul
#define EXCEPTION_EXECUTE_HANDLER 1
#define EXCEPTION_CONTINUE_SEARCH 0
#define EXCEPTION_ACCESS_VIOLATION 0xC0000005ul

static inline unsigned short _byteswap_ushort(unsigned short x) { return __builtin_bswap16((uint16_t)x); }
static inline unsigned long _byteswap_ulong(unsigned long x) { return __builtin_bswap32((uint32_t)x); }
static inline unsigned long GetExceptionCode() { return 0; }
static inline size_t VirtualQuery(const void*, MEMORY_BASIC_INFORMATION*, size_t) { return 0; }

#define __try if (true)
#define __except(x) else if (false)

#endif  // !_WIN32
#endif  // COGBOX_MAC_WIN32_SEH_H
