// macOS port: no-op stand-ins for features whose implementation needs an SDK patch this port does not carry.
//
// main_menu_exit.cpp needs rex/kernel/xam/net/ue3_script.h (COGBox SDK patch 77: scanning a UE3 script's
// bytecode), which the macOS SDK does not have yet. Lost: the "Exit Game" item added to the main menu; the
// game's own menu is untouched.
#if !defined(_WIN32)

#include "main_menu_exit.h"

namespace rex::glue {

bool PatchExitButton() {
  return true;  // nothing to do: the label is still installed by config_install.cpp
}
bool MatchesExitButton(const uint8_t*, uint32_t) {
  return false;
}
void ExitGame() {}

}  // namespace rex::glue

void Gow3InstallMainMenuExitIfRequested() {}

#endif  // !defined(_WIN32)
