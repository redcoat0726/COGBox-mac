// No-op implementations of the layer-0 subsystems that are Windows-only for now.
//
// Each of these lives in a file listed in GN_MACOS_EXCLUDED (see CMakeLists.txt) because its body
// is Win32: DXGI desktop duplication, Win32 unhandled-exception handling, an ImGui developer menu
// driven by Win32 dialogs, NVIDIA-Reflex-style latency hooks, a WMI system report, and a
// prompt-atlas overlay compositor. The rest of the port still calls into them, so the symbols have
// to exist. None is on the path a frame takes to the screen - what is lost is written next to each.
//
// Empty on Windows, where the real implementations are linked instead.
#if !defined(_WIN32)

#include <rex/cvar.h>
#include <xenos/dev_tools.h>
#include <xenos/renderer/prompt_overlay_compositor.h>
#include <xenos/social_ingame.h>

#include <imgui.h>

#include "renderer/dlss_framegen.h"
#include "renderer/xess_framegen.h"

// frame_capture.cpp - screenshots and frame capture through DXGI. Lost: screenshot requests are
// ignored and the frame-capture ring never fills. Rendering is unaffected.
void XenosInstallFrameCaptureIfRequested() {}
bool XenosTakeScreenshotRequest() {
  return false;
}
void XenosSaveScreenshot(const uint8_t*, uint32_t, uint32_t, uint32_t) {}
void XenosScreenshotSetPresented(bool) {}

// ingame_menu.cpp - the F7 developer menu and its settings pages. Lost: the menu, including the
// Resume/Restart/Quit controls. The game's own menus are untouched.
void XenosInstallInGameMenu(rex::ui::ImGuiDrawer*, rex::ui::ImmediateDrawer*, rex::ui::Window*,
                            rex::Runtime*) {}
void XenosShutdownInGameMenu() {}
bool XenosInGameMenuIsOpen() noexcept {
  return false;
}
bool XenosLiveMaxFps(int32_t*) {
  return false;  // no developer menu: nothing overrides the frame limiter
}
void XenosSetPromptGame(uint32_t) {}  // GitHub #223: no prompt overlays on macOS, nothing to build ahead
void XenosConfigureMenuFonts(ImFontAtlas*) {}  // the menu's font is only used by the missing menu

// crash_report.cpp / system_report.cpp - dumps for unhandled host exceptions, and the system
// report a bug report attaches. Lost: a crash takes the process down with a system dialog instead
// of writing a report.
void XenosInstallCrashHandler() {}
void XenosLogSystemReport(const char*) {}
void XenosCrashNote(const std::string&) {}

// latency_reflex.cpp - the latency-reduction path. Lost: nothing measurable on Metal; it is a
// Windows driver feature.
void XenosLatencyInstall() {}
void XenosLatencyFrameSubmitted() {}

// renderer/prompt_overlay_compositor.cpp - recognises the game's own button-prompt atlas so the
// on-disk copy can be suppressed while our key caps are drawn over it. Reporting "not an atlas"
// keeps the disk texture, which is what the game itself would have drawn.
namespace xenos::renderer::prompt {
bool IsPromptAtlasOrAlias(uint64_t) {
  return false;
}
}  // namespace xenos::renderer::prompt

// social_*.cpp - the games' online social worker (0.6.1). It needs the SDK's online/MasterClient
// patches (77-93), which this port's SDK does not carry yet. Lost: the Social page, pop-ups,
// invites and the online ping readout; offline play is untouched.
bool XenosSocialAvailable() {
  return false;
}
void XenosSocialStart() {}
SocialView XenosSocialView() {
  return {};
}
std::vector<SocialEvent> XenosSocialTakeEvents() {
  return {};
}

// renderer/dlss_framegen.cpp and renderer/xess_framegen.cpp - NVIDIA Streamline and Intel XeSS frame
// generation. Both are D3D12-only Windows paths; frame_generation.cpp forwards to them, so the symbols
// must exist. Lost: --gow2_frame_generation=dlss|xess on macOS (the Vulkan FSR path is separate).
bool XenosDlssFgInstall(bool, XenosDlssFgFallback) {
  return false;
}
bool XenosDlssFgActive() {
  return false;
}
bool XenosDlssFgOwnsLatency() {
  return false;
}
bool XenosDlssFgWanted() {
  return false;
}
uint32_t XenosDlssFgHudlessFormat() {
  return 0;
}
bool XenosDlssFgHudlessSize(uint32_t&, uint32_t&) {
  return false;
}
void XenosDlssFgSetInputs(void*, const XenosFgFrame*) {}
void XenosDlssFgFrameSubmitted() {}

bool XenosXefgInstall(bool, XenosXefgFallback) {
  return false;
}
bool XenosXefgActive() {
  return false;
}
bool XenosXefgOwnsLatency() {
  return false;
}
bool XenosXefgWanted() {
  return false;
}
uint32_t XenosXefgHudlessFormat() {
  return 0;
}
bool XenosXefgHudlessSize(uint32_t&, uint32_t&) {
  return false;
}
void XenosXefgSetInputs(void*, const XenosFgFrame*) {}
void XenosXefgFrameSubmitted() {}

// crash_report.cpp defines this cvar and frame_log.cpp reads it; there is no crash handler here,
// so it is only ever read, never written.
REXCVAR_DEFINE_STRING(gow2_crash_dir, "", "Gears2",
                      "Folder for crash reports (unused on macOS: no crash handler)");

#endif  // !defined(_WIN32)
