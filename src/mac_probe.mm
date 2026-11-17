// cogbox-mac: macOS-side host probes.
//
// Everything here answers one question: can this Mac host the COGBox ports at all, and through what? The Windows
// launcher asks the same of DXGI/AVX2/Windows-version; on macOS the interesting answers are the GPU, Metal, a
// Vulkan loader (the ports run on the KosmicKrisp ICD through libvulkan.1.dylib) and -
// for the x86-64 builds - Rosetta.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "mac_probe.h"

#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>

#include <cstdlib>

static std::string sysctl_str(const char *name) {
  size_t len = 0;
  if (sysctlbyname(name, nullptr, &len, nullptr, 0) != 0 || len == 0) return {};
  std::string out(len, '\0');
  if (sysctlbyname(name, out.data(), &len, nullptr, 0) != 0) return {};
  while (!out.empty() && out.back() == '\0') out.pop_back();
  return out;
}

static int sysctl_int(const char *name, int fallback = 0) {
  int v = fallback;
  size_t len = sizeof v;
  if (sysctlbyname(name, &v, &len, nullptr, 0) != 0) return fallback;
  return v;
}

static uint64_t sysctl_u64(const char *name, uint64_t fallback = 0) {
  uint64_t v = fallback;
  size_t len = sizeof v;
  if (sysctlbyname(name, &v, &len, nullptr, 0) != 0) return fallback;
  return v;
}

// Try to load a Vulkan loader. dlclose on failure only.
static bool try_vulkan(const char *path, std::string *version) {
  void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!h) return false;
  // A loadable loader is the signal; vkGetInstanceProcAddr proves it is really a Vulkan loader.
  // The driver (KosmicKrisp) is selected at launch through VK_DRIVER_FILES, not probed here.
  auto gipa = reinterpret_cast<void *(*)(void *, const char *)>(dlsym(h, "vkGetInstanceProcAddr"));
  if (!gipa) {
    dlclose(h);
    return false;
  }
  if (version) {
    for (const char *v : {"vkEnumerateInstanceVersion", "vkCreateInstance"})
      if (!gipa(nullptr, v)) {
        dlclose(h);
        return false;
      }
  }
  dlclose(h);
  return true;
}

MacInfo mac_probe() {
  MacInfo m;
  m.os_version = sysctl_str("kern.osproductversion");
  struct utsname u {};
  if (uname(&u) == 0) m.machine = u.machine;
  m.cpu_brand = sysctl_str("machdep.cpu.brand_string");
  if (m.cpu_brand.empty()) m.cpu_brand = sysctl_str("hw.model");
  m.cores = sysctl_int("hw.ncpu", 0);
  m.mem_bytes = sysctl_u64("hw.memsize", 0);
  m.translated = sysctl_int("sysctl.proc_translated", 0) == 1;

  // Rosetta: the daemon only exists on Apple silicon with the translation runtime installed.
  m.rosetta_present = [[NSFileManager defaultManager] fileExistsAtPath:@"/usr/libexec/rosetta/oahd"] ||
                      [[NSFileManager defaultManager] fileExistsAtPath:@"/Library/Apple/usr/libexec/oah"];
  const char *adv = std::getenv("ROSETTA_ADVERTISE_AVX");
  m.avx_advertised = adv && *adv && std::string(adv) != "0";

  if (@available(macOS 10.13, *)) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
      m.metal = true;
      m.gpu_name = dev.name ? dev.name.UTF8String : "";
      m.gpu_mem = dev.recommendedMaxWorkingSetSize;
      m.gpu_unified = dev.hasUnifiedMemory;
      if (@available(macOS 13.0, *)) m.gpu_mac2 = [dev supportsFamily:MTLGPUFamilyMac2];
    }
  }

  for (const char *p : {"/opt/homebrew/lib/libvulkan.1.dylib", "/opt/homebrew/lib/libvulkan.dylib",
                        "/usr/local/lib/libvulkan.1.dylib", "/usr/local/lib/libvulkan.dylib",
                        "libvulkan.1.dylib", "libvulkan.dylib"}) {
    std::string v;
    if (try_vulkan(p, &v)) m.vulkan_libs.emplace_back(p);
  }
  return m;
}
