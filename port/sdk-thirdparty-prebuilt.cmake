# macOS port: third-party dependencies taken from a prebuilt rexglue SDK.
#
# Upstream `thirdparty/CMakeLists.txt` builds 22 git submodules from source. Fetching them
# from source is unnecessary - the release SDK already ships
# every one of them as a static library plus installed headers - they are precisely what
# the shipped `librexruntime.dylib` was linked against. So this file declares the same
# target names as imported targets pointed at the release prefix.
#
# The one exception is imgui: upstream compiles it as an OBJECT library and the release
# exports no `libimgui.a`, so its five translation units are built here from sources
# fetched at the commit the SDK pins.
#
# This file is installed over `thirdparty/CMakeLists.txt` in the patched SDK tree by
# port/build_sdk.sh. It is not a general-purpose substitute: it assumes the release
# prefix's layout (include/, lib/*.a, lib/*.dylib).

include(${PROJECT_SOURCE_DIR}/cmake/rexglue_vulkan_stack.cmake)

set(REXGLUE_PORT_PREFIX "" CACHE PATH
    "unpacked rexglue SDK release providing the prebuilt third-party libraries and headers")
if(NOT REXGLUE_PORT_PREFIX)
  message(FATAL_ERROR "REXGLUE_PORT_PREFIX must point at the unpacked rexglue mac-arm64 release")
endif()
set(_RP_INC "${REXGLUE_PORT_PREFIX}/include")
set(_RP_LIB "${REXGLUE_PORT_PREFIX}/lib")

# --- helpers ---------------------------------------------------------------------------------

function(_rp_static target lib)
  if(NOT TARGET ${target})
    add_library(${target} STATIC IMPORTED GLOBAL)
    set_target_properties(${target} PROPERTIES
      IMPORTED_LOCATION "${_RP_LIB}/${lib}"
      INTERFACE_INCLUDE_DIRECTORIES "${_RP_INC}")
    if(ARGC GREATER 2)
      set_target_properties(${target} PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${ARGN}")
    endif()
  endif()
endfunction()

function(_rp_header target)
  if(NOT TARGET ${target})
    add_library(${target} INTERFACE)
    target_include_directories(${target} SYSTEM INTERFACE ${ARGN})
  endif()
endfunction()

function(_rp_shared target lib)
  if(NOT TARGET ${target})
    add_library(${target} SHARED IMPORTED GLOBAL)
    set_target_properties(${target} PROPERTIES IMPORTED_LOCATION "${_RP_LIB}/${lib}")
  endif()
endfunction()

# --- header-only -----------------------------------------------------------------------------

_rp_header(disruptorplus "${_RP_INC}/disruptorplus")
_rp_header(renderdoc     "${_RP_INC}/renderdoc")
_rp_header(tomlplusplus  "${_RP_INC}")
_rp_header(simde         "${_RP_INC}" "${_RP_INC}/simde")
_rp_header(utf8cpp       "${_RP_INC}" "${_RP_INC}/utf8cpp")
_rp_header(spirv-tools-headers "${_RP_INC}")
_rp_header(vulkan-headers "${_RP_INC}")
add_library(Vulkan::Headers ALIAS vulkan-headers)

# --- compiled libraries (prebuilt) -----------------------------------------------------------

_rp_static(aes128  libaes128.a)
# lzx.cpp includes <lzx.h>/<mspack.h>, which are mspack's own headers and are not installed
# with the release; they come from the submodule's cabextract tree.
_rp_static(mspack  libmspack.a "${_RP_INC}" "${CMAKE_CURRENT_SOURCE_DIR}/libmspack/cabextract/mspack")
_rp_static(o1heap  libo1heap.a)
_rp_static(xxhash  libxxhash.a)
add_library(xxHash::xxhash ALIAS xxhash)
_rp_static(fmt     libfmt.a)
add_library(fmt::fmt ALIAS fmt)
_rp_static(spdlog  libspdlog.a)
# The release's spdlog is built with SPDLOG_FMT_EXTERNAL (upstream's thirdparty sets it), so its
# headers expect an external fmt rather than the bundled copy that an install does not ship.
set_target_properties(spdlog PROPERTIES
  INTERFACE_COMPILE_DEFINITIONS "SPDLOG_FMT_EXTERNAL"
  INTERFACE_LINK_LIBRARIES fmt)
add_library(spdlog::spdlog ALIAS spdlog)
_rp_static(SDL3    libSDL3.a)
# A static SDL3 carries no link interface, so the frameworks it uses have to be named here.
# These are the ones the release's SDL3 build references on macOS.
set_target_properties(SDL3 PROPERTIES INTERFACE_LINK_LIBRARIES
  "-framework CoreAudio;-framework AudioToolbox;-framework CoreFoundation;-framework CoreMedia;-framework CoreVideo;-framework Cocoa;-framework IOKit;-framework ForceFeedback;-framework Carbon;-framework Metal;-framework QuartzCore;-framework AVFoundation;-framework UniformTypeIdentifiers;-framework GameController;-framework CoreHaptics")
add_library(SDL3::SDL3 ALIAS SDL3)

# tiny-aes and disasm have no prebuilt archives under those names. tiny-aes is only the AES
# implementation that `aes128` already provides (see upstream: both are AES-C, different forks),
# and disasm's sources ship with the repository, so it is built from them below.
if(NOT TARGET tiny-aes)
  add_library(tiny-aes INTERFACE)
  target_link_libraries(tiny-aes INTERFACE aes128)
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/disasm/CMakeLists.txt")
  add_subdirectory(disasm)
else()
  _rp_static(disasm libdisasm.a "${CMAKE_CURRENT_SOURCE_DIR}/disasm")
endif()

# --- imgui: object library, no prebuilt archive -----------------------------------------------

set(IMGUI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/imgui")
if(EXISTS "${IMGUI_DIR}/imgui.cpp")
  if(NOT TARGET imgui)
    add_library(imgui OBJECT
      ${IMGUI_DIR}/imgui.cpp
      ${IMGUI_DIR}/imgui_demo.cpp
      ${IMGUI_DIR}/imgui_draw.cpp
      ${IMGUI_DIR}/imgui_tables.cpp
      ${IMGUI_DIR}/imgui_widgets.cpp)
  endif()
  target_include_directories(imgui PUBLIC
    $<BUILD_INTERFACE:${IMGUI_DIR}>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
  target_compile_options(imgui PRIVATE -w)
else()
  message(FATAL_ERROR "imgui sources missing at ${IMGUI_DIR}; clone the rexglue SDK into sdk-src (see Gears2-Native/patches/README.md)")
endif()
add_library(imgui::imgui ALIAS imgui)

# --- Vulkan stack ------------------------------------------------------------------------------
# The release ships the Vulkan loader as a dylib plus the installed headers, so the upstream
# "build the loader and driver from pinned submodules" branch collapses into imports. The ICD
# used at run time is KosmicKrisp (LunarG's macOS Vulkan SDK), selected via VK_DRIVER_FILES.

if(REXGLUE_USE_VULKAN)
  _rp_shared(vulkan    libvulkan.1.dylib)
  # Name the SDK's staging helper looks for (_rexglue_stage_macos_vulkan_runtime).
  if(NOT TARGET Vulkan::Loader)
    add_library(Vulkan::Loader ALIAS vulkan)
  endif()
  # CMake only allows `::` in names for IMPORTED targets, so the namespaced spelling has to be
  # an alias of a plain one.
  if(NOT TARGET VulkanMemoryAllocator)
    add_library(VulkanMemoryAllocator INTERFACE)
    target_include_directories(VulkanMemoryAllocator SYSTEM INTERFACE "${_RP_INC}")
  endif()
  if(NOT TARGET VulkanMemoryAllocator::VulkanMemoryAllocator)
    add_library(VulkanMemoryAllocator::VulkanMemoryAllocator ALIAS VulkanMemoryAllocator)
  endif()
  # VMA's own CMake package spells it GPUOpen::; the SDK's consumers use that form.
  if(NOT TARGET GPUOpen::VulkanMemoryAllocator)
    add_library(GPUOpen::VulkanMemoryAllocator ALIAS VulkanMemoryAllocator)
  endif()
  # VMA's own CMake package spells it GPUOpen::; the SDK's consumers use that form.
  if(NOT TARGET GPUOpen::VulkanMemoryAllocator)
    add_library(GPUOpen::VulkanMemoryAllocator ALIAS VulkanMemoryAllocator)
  endif()

  # glslang: the release ships glslang, SPIRV, MachineIndependent, GenericCodeGen, OGLCompiler
  # and OSDependent as separate archives, mirroring the submodule's targets - but it ships no
  # glslang headers at all (its include/ has no glslang/), so the archives alone cannot be used.
  # Point these targets at the submodule's source tree, the same way mspack above takes its
  # headers from cabextract: otherwise every consumer stops at
  # "glslang/Public/ShaderLang.h: No such file".
  set(_glslang_includes "${_RP_INC}")
  set(_glslang_found 0)
  foreach(_glslang_candidate
      "${CMAKE_CURRENT_SOURCE_DIR}/glslang"         # thirdparty/glslang: <glslang/Public/...>, <SPIRV/...>
      "${CMAKE_CURRENT_SOURCE_DIR}/vendor-headers") # a copy of the same headers, when the tree has one
    if(EXISTS "${_glslang_candidate}/glslang/Public/ShaderLang.h")
      list(APPEND _glslang_includes "${_glslang_candidate}")
      set(_glslang_found 1)
    endif()
  endforeach()
  if(NOT _glslang_found AND NOT EXISTS "${_RP_INC}/glslang/Public/ShaderLang.h")
    message(WARNING
        "glslang headers not found: the release SDK ships libglslang.a without its headers, and "
        "thirdparty/glslang is empty. Run 'git submodule update --init --recursive' in the SDK "
        "source tree (see docs/building-macos.md), then rebuild.")
  endif()
  foreach(_glslang_lib glslang SPIRV MachineIndependent GenericCodeGen OGLCompiler OSDependent)
    if(EXISTS "${_RP_LIB}/lib${_glslang_lib}.a")
      _rp_static(${_glslang_lib} "lib${_glslang_lib}.a" ${_glslang_includes})
    endif()
  endforeach()
  if(TARGET SPIRV AND NOT TARGET glslang::SPIRV)
    add_library(glslang::SPIRV ALIAS SPIRV)
  endif()
  if(TARGET glslang AND NOT TARGET glslang::glslang)
    add_library(glslang::glslang ALIAS glslang)
  endif()
endif()

# --- FFmpeg -------------------------------------------------------------------------------------
# libavutil/libavcodec are built upstream from a subset of FFmpeg's C sources. Nothing under
# src/ includes `libavcodec/` or `libavutil/` (checked: 0 files), so these targets exist only
# to satisfy the link graph. They are declared when the archives are present, and skipped
# otherwise rather than pointing an imported target at a directory that does not exist.

set(_RP_FFMPEG "${CMAKE_CURRENT_SOURCE_DIR}/FFmpeg")
if(EXISTS "${_RP_LIB}/liblibavutil.a")
  _rp_static(libavutil liblibavutil.a "${_RP_FFMPEG}")
endif()
if(EXISTS "${_RP_LIB}/liblibavcodec.a")
  _rp_static(libavcodec liblibavcodec.a "${_RP_FFMPEG}")
  if(TARGET libavcodec AND TARGET libavutil)
    set_target_properties(libavcodec PROPERTIES INTERFACE_LINK_LIBRARIES libavutil)
  endif()
endif()

# --- Tracy (optional) ---------------------------------------------------------------------------

if(REXGLUE_ENABLE_TRACY)
  _rp_shared(TracyClient libTracyClient.dylib)
  if(NOT TARGET Tracy::TracyClient)
    add_library(Tracy::TracyClient ALIAS TracyClient)
  endif()
endif()

# --- D3D12 / DXC (not used on macOS) ------------------------------------------------------------

if(REXGLUE_USE_D3D12 AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/dxc/include")
  add_library(dxc-headers INTERFACE)
  target_include_directories(dxc-headers INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/dxc/include>)
endif()

message(STATUS "rexglue macOS port: third-party targets imported from ${REXGLUE_PORT_PREFIX}")
