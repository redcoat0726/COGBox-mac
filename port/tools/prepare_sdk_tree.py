#!/usr/bin/env python3
"""Apply this port's edits to a freshly patched rexglue SDK tree.

The SDK is built with its third-party dependencies imported from the release prefix instead
of its 22 git submodules. That needs two changes to upstream's build files, both of which
are made here rather than in the shell so they stay readable and idempotent:

  1. `include(cmake/rexglue_install.cmake)` is skipped. With imported third-party targets,
     `install(TARGETS)` fails (CMake will not install, or export a target that links, an
     imported target). Nothing needs installing: COGBox consumes this tree through
     `add_subdirectory(REXSDK_DIR)`.

  2. `thirdparty/vendor-headers` goes on the include path. nlohmann/json and inja are
     submodules upstream; both are single headers, so they live there instead.

    python3 tools/prepare_sdk_tree.py sdk-patched
"""
import argparse
import re
import sys

INSTALL_INCLUDE = "include(cmake/rexglue_install.cmake)"
VENDOR_LINE = ("include_directories(${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/vendor-headers)"
               "  # REXGLUE_PORT_VENDOR_HEADERS\n")
MARK_INSTALL = "REXGLUE_PORT_PREBUILT_SKIP_INSTALL"
MARK_VENDOR = "REXGLUE_PORT_VENDOR_HEADERS"


def patch(path, changes):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    original = src
    for apply in changes:
        src = apply(src)
    if src != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
    return src != original


def skip_install(src):
    if MARK_INSTALL in src:
        return src
    if INSTALL_INCLUDE not in src:
        sys.exit("prepare_sdk_tree: install include not found - has the SDK layout changed?")
    return src.replace(INSTALL_INCLUDE,
                       "if(NOT REXGLUE_PORT_PREBUILT)\n"
                       "    include(cmake/rexglue_install.cmake)\n"
                       "else()  # " + MARK_INSTALL + "\n"
                       "    message(STATUS \"rexglue macOS port: install rules skipped\")\n"
                       "endif()", 1)


def add_vendor_headers(src):
    if MARK_VENDOR in src:
        # When the SDK is consumed with add_subdirectory(REXSDK_DIR), CMAKE_SOURCE_DIR is the *outer*
        # project's root, so the vendor path has to be relative to this file instead.
        return src.replace(
            "include_directories(${CMAKE_SOURCE_DIR}/thirdparty/vendor-headers)",
            "include_directories(${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/vendor-headers)")
    # project() spans several lines; inserting inside the call makes CMake read the path as a
    # language name ("CMAKE_<path>_COMPILER not set").
    i = src.index("project(")
    j = src.index("\n)\n", i) + 3
    return src[:j] + VENDOR_LINE + src[j:]


def skip_codegen(src):
    """Leave out the recompiler library and its CLI.

    COGBox's layer 0 does not reference `rexcodegen` - only `src/rexglue` (the command line
    recompiler) links it - and codegen cannot run without the player's own disc image anyway.
    Its headers also expect to be parsed in a fixed order that only the upstream build
    assumes, which costs more to untangle than it is worth here.

    A placeholder `rex::rexglue` is declared in its place: COGBox's build defines its codegen
    step unconditionally and spells the tool as `$<TARGET_FILE:rex::rexglue>`, so the name has
    to resolve even though nothing runs it. It points at /usr/bin/false - building the game
    program will fail loudly rather than silently produce a half-generated tree. Re-enable by
    removing this from the call list in main().
    """
    if "rexglue_port_placeholder" in src:   # already done, placeholder and all
        return src
    for line, why in (("add_subdirectory(src/codegen)", "recompiler library"),
                      ("add_subdirectory(src/rexglue)", "recompiler command line tool")):
        if line in src:
            src = src.replace(line,
                              f"# {line}  # REXGLUE_PORT_SKIP_CODEGEN: {why} left out of the macOS port build\n", 1)
    src += (
        "\n# REXGLUE_PORT_SKIP_CODEGEN: placeholder for the recompiler CLI (see tools/prepare_sdk_tree.py).\n"
        "# Nothing runs it until the game program is built, which needs the player's own disc.\n"
        "if(NOT TARGET rex::rexglue)\n"
        "    add_executable(rexglue_port_placeholder IMPORTED GLOBAL)\n"
        "    set_target_properties(rexglue_port_placeholder PROPERTIES IMPORTED_LOCATION \"/usr/bin/false\")\n"
        "    add_executable(rex::rexglue ALIAS rexglue_port_placeholder)\n"
        "endif()\n")
    return src


EXPORT_TARGETS = "cmake/rexglue_export_targets.cmake"
CODEGEN_EXPORT = "set_target_properties(rexcodegen PROPERTIES EXPORT_NAME codegen)"


def guard_codegen_export(tree):
    """v0.10.1 exports `rexcodegen` by name; skipping the library makes that line an error."""
    path = f"{tree}/{EXPORT_TARGETS}"
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        return False            # v0.10.0 has no such file
    if "REXGLUE_PORT_SKIP_CODEGEN" in src or CODEGEN_EXPORT not in src:
        return False
    src = src.replace(CODEGEN_EXPORT,
                      "if(TARGET rexcodegen)  # REXGLUE_PORT_SKIP_CODEGEN\n"
                      "    " + CODEGEN_EXPORT + "\n"
                      "endif()", 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return True


STAGE_HELPER = "cmake/rexglue_helpers.cmake"


LOGGING_CPP = "src/core/logging.cpp"
LOGGER_OLD = """  auto sinks = BuildCategorySinks(name);
  auto logger = std::make_shared<spdlog::logger>(name, sinks.begin(), sinks.end());
  logger->set_level(ResolveCategoryLevel(name));
  logger->flush_on(g_config.flush_level);
  spdlog::register_logger(logger);
  return logger;"""
LOGGER_NEW = """  // macOS port: spdlog::register_logger throws when the name is taken, and here the same category
  // is reached from both the game executable and librexruntime. Reuse what is registered instead of
  // aborting startup; the level and flush policy below still apply.
  if (auto existing = spdlog::get(name)) {
    existing->set_level(ResolveCategoryLevel(name));
    existing->flush_on(g_config.flush_level);
    return existing;
  }
  auto sinks = BuildCategorySinks(name);
  auto logger = std::make_shared<spdlog::logger>(name, sinks.begin(), sinks.end());
  logger->set_level(ResolveCategoryLevel(name));
  logger->flush_on(g_config.flush_level);
  spdlog::register_logger(logger);
  return logger;"""


def fix_logger_registration(tree):
    """Registering the same log category twice aborts startup with an spdlog exception.

    The game executable and librexruntime each link their own copy of the static spdlog, and on
    macOS both end up registering the "core" category in the same registry. Windows does not hit
    it (the runtime is loaded once, before any category is touched). Reusing the existing logger
    is the behaviour the rest of the code assumes anyway.
    """
    path = f"{tree}/{LOGGING_CPP}"
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        return False
    if "macOS port: spdlog::register_logger throws" in src or LOGGER_OLD not in src:
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(LOGGER_OLD, LOGGER_NEW, 1))
    return True


# The SDK's staging helper assumes a macOS Vulkan runtime made of a loader + MoltenVK, and
# FATAL_ERRORs when the MoltenVK target is absent. This port runs on KosmicKrisp (LunarG's macOS
# Vulkan SDK, selected through VK_DRIVER_FILES) and has no MoltenVK target at all, so replace the
# whole helper with one that stages only the loader. Matching the whole function (rather than just
# its POST_BUILD block) also removes the target check, and works on trees already patched by the
# older "optional MoltenVK copy" version.
STAGE_FN_RE = re.compile(
    r"function\(_rexglue_stage_macos_vulkan_runtime target_name\).*?\nendfunction\(\)",
    re.S)

STAGE_FN_NEW = """function(_rexglue_stage_macos_vulkan_runtime target_name)
    # This port's macOS Vulkan runtime is just the loader. The ICD is KosmicKrisp from the
    # LunarG macOS Vulkan SDK, chosen at launch with VK_DRIVER_FILES; no other driver is used.
    if(TARGET Vulkan::Loader)
        set(_rexglue_vulkan_loader Vulkan::Loader)
    elseif(TARGET rex::vulkan-loader)
        set(_rexglue_vulkan_loader rex::vulkan-loader)
    else()
        message(FATAL_ERROR "rexglue: the macOS Vulkan loader target is unavailable")
    endif()

    add_custom_command(TARGET ${target_name} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/lib"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:${_rexglue_vulkan_loader}>"
            "$<TARGET_FILE_DIR:${target_name}>/vulkan/lib/libvulkan.1.dylib"
        VERBATIM
    )
endfunction()"""


def drop_moltenvk_staging(tree):
    """Remove every MoltenVK reference from the SDK's staging helper."""
    path = f"{tree}/{STAGE_HELPER}"
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        return False
    if "MoltenVK" not in src and "_rexglue_moltenvk" not in src:
        return False
    new, n = STAGE_FN_RE.subn(STAGE_FN_NEW, src, count=1)
    if n == 0:
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tree")
    ap.add_argument("--skip-codegen", action="store_true",
                    help="leave out src/codegen and src/rexglue (they build fine now; only useful when "
                         "debugging the rest of the SDK)")
    args = ap.parse_args()
    tree = args.tree

    steps = [skip_install, add_vendor_headers]
    if args.skip_codegen:
        steps.append(skip_codegen)
    changed = patch(f"{tree}/CMakeLists.txt", steps)
    if guard_codegen_export(tree):
        changed = True
    if fix_logger_registration(tree):
        changed = True
    # Replaces the whole staging helper, so it must run after any patch that edits its body.
    if drop_moltenvk_staging(tree):
        changed = True
    print(f"prepare_sdk_tree: {'updated' if changed else 'already prepared'} {tree}")



if __name__ == "__main__":
    main()
