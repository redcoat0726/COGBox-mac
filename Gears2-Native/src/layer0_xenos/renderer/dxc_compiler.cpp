// Layer 0 (game-free): DXC in-process (IDxcCompiler3), loaded at run time from dxcompiler.dll. No link-time
// dependency: if the DLL is missing the shadow renderer logs it and stays off, the game runs as before. The build
// copies third_party\dxc-<version>\bin\x64\dxcompiler.dll and dxil.dll (cmake/gn_deps.cmake) next to gow2.exe (CMake POST_BUILD); DXC loads
// dxil.dll itself (normal DLL search order, the exe folder first) to sign the DXIL - without it D3D12 rejects the
// bytecode, which the compile messages then say.
//
// Arguments are the S3.3 pinned set (notes/39): -E main -HV 2021 -Gis -denorm ftz, Shader Model 6.6; SPIR-V adds
// -spirv -fspv-target-env=vulkan1.3 (Vulkan backend, later). Our code (MIT).
#include <xenos/renderer/shader_cache.h>
#include <atomic>
#include <filesystem>

#ifndef _WIN32

// macOS / Linux: the same DXC, driven through its command line instead of the COM API. dxcapi.h needs the COM
// base interfaces (IUnknown, HRESULT), which do not exist off Windows, and this port only compiles a handful of
// built-in shaders at start-up - one process each is far simpler than re-creating the COM plumbing.
//   --gow2_dxc_dir=<dir>  looks for <dir>/dxc, <dir>/bin/dxc, <dir>/dxcompiler
//   empty                 looks next to the executable, then in ./third_party/dxc-macos/bin
#include <unistd.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace xenos::renderer {
namespace {

std::string ShellQuote(const std::string& s) {
  std::string out = "'";
  for (char c : s) {
    if (c == '\'') out += "'\\''";
    else out += c;
  }
  out += "'";
  return out;
}

const char* ProfileOf(gpu::ShaderStage stage) {
  switch (stage) {
    case gpu::ShaderStage::kVertex: return "vs_6_6";
    case gpu::ShaderStage::kPixel: return "ps_6_6";
    case gpu::ShaderStage::kGeometry: return "gs_6_6";
    default: return "cs_6_6";
  }
}

class DxcCliCompiler final : public ShaderCompiler {
 public:
  DxcCliCompiler(std::string exe, std::string version) : exe_(std::move(exe)), version_(std::move(version)) {}

  std::string Describe() const override { return "DXC " + version_ + " (command line)"; }

  std::string CacheTag(gpu::ShaderIL il) const override {
    return "dxc-cli " + version_ +
           (il == gpu::ShaderIL::kDxil ? " -HV 2021 -Gis -denorm ftz sm6.6"
                                       : " -HV 2021 -Gis -spirv vulkan1.3 sm6.6 shifts b0 t100 s200 u300 unkfmt");
  }

  bool Compile(const std::string& hlsl, gpu::ShaderStage stage, gpu::ShaderIL il, std::vector<uint8_t>& out,
               std::string& messages) override {
    static std::atomic<uint32_t> seq{0};
    const std::string base = (std::filesystem::temp_directory_path() /
                              ("gow2dxc-" + std::to_string(::getpid()) + "-" + std::to_string(seq.fetch_add(1))))
                                 .string();
    const std::string src = base + ".hlsl";
    const std::string dst = base + (il == gpu::ShaderIL::kDxil ? ".dxil" : ".spv");
    const std::string err = base + ".txt";
    {
      FILE* f = std::fopen(src.c_str(), "wb");
      if (!f) {
        messages = "cannot write " + src;
        return false;
      }
      std::fwrite(hlsl.data(), 1, hlsl.size(), f);
      std::fclose(f);
    }
    std::string cmd = ShellQuote(exe_) + " -T " + ProfileOf(stage) + " -E main -HV 2021 -Gis";
    if (il == gpu::ShaderIL::kDxil) {
      cmd += " -denorm ftz";
    } else {
      cmd += " -spirv -fspv-target-env=vulkan1.3 -fspv-use-unknown-image-format"
             " -fvk-b-shift 0 0 -fvk-t-shift 100 0 -fvk-s-shift 200 0 -fvk-u-shift 300 0";
    }
    cmd += " -Fo " + ShellQuote(dst) + " " + ShellQuote(src) + " > " + ShellQuote(err) + " 2>&1";
    const int rc = std::system(cmd.c_str());
    {
      FILE* f = std::fopen(err.c_str(), "rb");
      if (f) {
        std::array<char, 4096> buf{};
        const size_t n = std::fread(buf.data(), 1, buf.size() - 1, f);
        messages.assign(buf.data(), n);
        std::fclose(f);
      }
    }
    bool ok = false;
    if (rc == 0) {
      if (FILE* f = std::fopen(dst.c_str(), "rb")) {
        std::fseek(f, 0, SEEK_END);
        const long size = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        if (size > 0) {
          out.resize(size_t(size));
          ok = std::fread(out.data(), 1, size_t(size), f) == size_t(size);
        }
        std::fclose(f);
      }
    }
    std::remove(src.c_str());
    std::remove(dst.c_str());
    std::remove(err.c_str());
    if (!ok && messages.empty()) messages = "dxc exited with " + std::to_string(rc);
    return ok;
  }

 private:
  std::string exe_;
  std::string version_;
};

bool FileExists(const std::filesystem::path& p) {
  std::error_code ec;
  return std::filesystem::is_regular_file(p, ec);
}

}  // namespace

std::unique_ptr<ShaderCompiler> CreateDxcCompiler(const std::filesystem::path& dir, std::string& error) {
  std::vector<std::filesystem::path> candidates;
  if (!dir.empty()) {
    candidates.push_back(dir / "dxc");
    candidates.push_back(dir / "bin" / "dxc");
  }
  std::error_code ec;
  const auto exe_dir = std::filesystem::current_path(ec);
  candidates.push_back(exe_dir / "dxc");
  candidates.push_back(exe_dir / "third_party" / "dxc-macos" / "bin" / "dxc");
  candidates.push_back(exe_dir / ".." / ".." / "third_party" / "dxc-macos" / "bin" / "dxc");
  for (const auto& c : candidates) {
    if (FileExists(c)) {
      return std::make_unique<DxcCliCompiler>(c.string(), "1.9.2607");
    }
  }
  error = "dxc not found (looked in " + (dir.empty() ? std::string("the working directory") : dir.string()) +
          "); put the macOS dxc build in third_party/dxc-macos/bin or pass --gow2_dxc_dir";
  return nullptr;
}

}  // namespace xenos::renderer

#else

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
// dxcapi.h needs the COM base interfaces, which WIN32_LEAN_AND_MEAN leaves out of windows.h.
#include <objidl.h>
#include <unknwn.h>
#ifndef _Maybenull_
#define _Maybenull_  // SAL annotation used by dxcapi.h; the Windows SDK's sal.h defines it
#endif
#include <dxcapi.h>

#include <cstdio>
#include <vector>

#include "shared_dlls.h"  // shared049: <COGBox>\shared when no --gow2_dxc_dir

namespace xenos::renderer {
namespace {

template <typename T>
void SafeRelease(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

class DxcCompiler final : public ShaderCompiler {
 public:
  ~DxcCompiler() override {
    SafeRelease(compiler_);
    SafeRelease(utils_);
    // The DLL stays loaded: COM objects from it may still be referenced during process exit.
  }

  bool Init(const std::filesystem::path& dll_dir, std::string& error) {
    std::filesystem::path dir = dll_dir;
    if (dir.empty()) {
      wchar_t exe[MAX_PATH] = {};
      GetModuleFileNameW(nullptr, exe, MAX_PATH);
      dir = std::filesystem::path(exe).parent_path();
      // shared049: no --gow2_dxc_dir (a game started without the launcher) and none beside the exe -> <COGBox>\shared
      if (!gn_shared_dlls::FileThere((dir / L"dxcompiler.dll").wstring()) && !gn_shared_dlls::SharedDir().empty())
        dir = std::filesystem::path(gn_shared_dlls::SharedDir());
    }
    const std::filesystem::path dll = dir / L"dxcompiler.dll";
    // LOAD_WITH_ALTERED_SEARCH_PATH: dxil.dll is then found next to dxcompiler.dll too.
    module_ = LoadLibraryExW(dll.wstring().c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module_) {
      error = "could not load " + dll.string() + " (error " + std::to_string(GetLastError()) + ")";
      return false;
    }
    auto create = reinterpret_cast<DxcCreateInstanceProc>(
        reinterpret_cast<void*>(GetProcAddress(module_, "DxcCreateInstance")));
    if (!create) {
      error = "DxcCreateInstance not found in " + dll.string();
      return false;
    }
    if (FAILED(create(CLSID_DxcUtils, IID_PPV_ARGS(&utils_))) ||
        FAILED(create(CLSID_DxcCompiler, IID_PPV_ARGS(&compiler_)))) {
      error = "DxcCreateInstance failed";
      return false;
    }
    IDxcVersionInfo* info = nullptr;
    if (SUCCEEDED(compiler_->QueryInterface(IID_PPV_ARGS(&info)))) {
      UINT32 major = 0, minor = 0;
      info->GetVersion(&major, &minor);
      version_ = std::to_string(major) + "." + std::to_string(minor);
      info->Release();
    }
    IDxcVersionInfo2* info2 = nullptr;
    if (SUCCEEDED(compiler_->QueryInterface(IID_PPV_ARGS(&info2)))) {
      UINT32 commits = 0;
      char* hash = nullptr;
      if (SUCCEEDED(info2->GetCommitInfo(&commits, &hash)) && hash) {
        version_ += std::string(" (") + hash + ")";
        CoTaskMemFree(hash);
      }
      info2->Release();
    }
    path_ = dll.string();
    return true;
  }

  std::string Describe() const override { return "DXC " + version_ + " in-process from " + path_; }

  std::string CacheTag(gpu::ShaderIL il) const override {
    return "dxc " + version_ + (il == gpu::ShaderIL::kDxil ? (gpu::g_dxil_shader_model == 65 ? " -HV 2021 -Gis -denorm ftz sm6.5" : " -HV 2021 -Gis -denorm ftz sm6.6") :
                                                        " -HV 2021 -Gis -spirv vulkan1.3 sm6.6 shifts b0 t100 s200 u300 unkfmt");
  }

  bool Compile(const std::string& hlsl, gpu::ShaderStage stage, gpu::ShaderIL il, std::vector<uint8_t>& out,
               std::string& messages) override {
    // 0.6.1: Shader Model 6.5 on a D3D12 device without 6.6 (gpu::g_dxil_shader_model); SPIR-V keeps 6.6's HLSL rules
    const bool sm65 = il == gpu::ShaderIL::kDxil && gpu::g_dxil_shader_model == 65;
    const wchar_t* profile = stage == gpu::ShaderStage::kVertex   ? (sm65 ? L"vs_6_5" : L"vs_6_6")
                             : stage == gpu::ShaderStage::kPixel  ? (sm65 ? L"ps_6_5" : L"ps_6_6")
                             : stage == gpu::ShaderStage::kGeometry ? (sm65 ? L"gs_6_5" : L"gs_6_6")
                                                             : (sm65 ? L"cs_6_5" : L"cs_6_6");
    std::vector<const wchar_t*> args = {L"-T", profile, L"-E", L"main", L"-HV", L"2021", L"-Gis"};
    if (il == gpu::ShaderIL::kDxil) {
      args.push_back(L"-denorm");
      args.push_back(L"ftz");
    } else {
      args.push_back(L"-spirv");
      args.push_back(L"-fspv-target-env=vulkan1.3");
      args.push_back(L"-fspv-use-unknown-image-format");  // VKA1: RW images take the view format, not Rgba32f
      // Notes/68 (Vulkan backend): registers without [[vk::binding]] (our fixed shaders, the memexport u0) land in set 0 at
      // these offsets; the backend moves them into its layout (vulkan_backend.cpp RemapBindings).
      for (const wchar_t* a : {L"-fvk-b-shift", L"0", L"0", L"-fvk-t-shift", L"100", L"0", L"-fvk-s-shift", L"200", L"0",
                               L"-fvk-u-shift", L"300", L"0"})
        args.push_back(a);
    }
    DxcBuffer source{hlsl.data(), hlsl.size(), DXC_CP_UTF8};
    IDxcResult* result = nullptr;
    HRESULT hr = compiler_->Compile(&source, args.data(), UINT32(args.size()), nullptr, IID_PPV_ARGS(&result));
    if (FAILED(hr) || !result) {
      char b[64];
      std::snprintf(b, sizeof(b), "IDxcCompiler3::Compile failed (0x%08lX)", static_cast<unsigned long>(hr));
      messages = b;
      return false;
    }
    IDxcBlobUtf8* errors = nullptr;
    if (SUCCEEDED(result->GetOutput(DXC_OUT_ERRORS, IID_PPV_ARGS(&errors), nullptr)) && errors &&
        errors->GetStringLength()) {
      messages.assign(errors->GetStringPointer(), errors->GetStringLength());
    }
    SafeRelease(errors);
    HRESULT status = E_FAIL;
    result->GetStatus(&status);
    bool ok = false;
    if (SUCCEEDED(status)) {
      IDxcBlob* object = nullptr;
      if (SUCCEEDED(result->GetOutput(DXC_OUT_OBJECT, IID_PPV_ARGS(&object), nullptr)) && object &&
          object->GetBufferSize()) {
        const auto* p = static_cast<const uint8_t*>(object->GetBufferPointer());
        out.assign(p, p + object->GetBufferSize());
        ok = true;
      }
      SafeRelease(object);
    }
    SafeRelease(result);
    return ok;
  }

 private:
  HMODULE module_ = nullptr;
  IDxcUtils* utils_ = nullptr;
  IDxcCompiler3* compiler_ = nullptr;
  std::string version_ = "?", path_;
};

}  // namespace

std::unique_ptr<ShaderCompiler> CreateDxcCompiler(const std::filesystem::path& dll_dir, std::string& error) {
  auto c = std::make_unique<DxcCompiler>();
  if (!c->Init(dll_dir, error)) return nullptr;
  return c;
}

}  // namespace xenos::renderer

#endif  // _WIN32
