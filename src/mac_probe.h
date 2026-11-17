// cogbox-mac: macOS-side host probes (no game code, no SDK).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct MacInfo {
  std::string os_version;      // "27.2"
  std::string machine;         // "arm64"
  std::string cpu_brand;       // "Apple M5 Pro"
  int cores = 0;
  uint64_t mem_bytes = 0;
  bool translated = false;     // this process runs under Rosetta
  bool rosetta_present = false;
  bool avx_advertised = false; // ROSETTA_ADVERTISE_AVX is set
  // Metal
  bool metal = false;
  std::string gpu_name;
  uint64_t gpu_mem = 0;
  bool gpu_unified = false;
  bool gpu_mac2 = false;       // MTLGPUFamilyMac2
  // Vulkan loader (the ICD is KosmicKrisp, chosen at launch)
  std::vector<std::string> vulkan_libs;  // loadable Vulkan loader paths
};

MacInfo mac_probe();
