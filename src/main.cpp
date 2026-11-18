// cogbox-mac: the macOS side of COGBox.
//
// What this program is, in one line: the half of the COGBox launcher that does not draw anything - recognising a
// player's own copy (disc image, Games on Demand folder, title update package), checking it against the fingerprints
// the ports are built for, and unpacking it into the folder layout the ports read.
//
// Why it exists: COGBox's launcher is a Windows program (Win32 + SDL3 + ImGui), but the filesystem half of it
// (Gears2-Native/cogbox/src/x360fs.cpp: XDVDFS, STFS, SVOD, LZX) is plain C++17 with no Windows calls at all.
// That file is compiled here exactly as it is - not copied - and this program is the macOS shell around it, so
// upstream's fixes arrive with a merge instead of drifting. A Mac can then do the same job: read the
// player's copy, verify it, unpack it, and say what is still missing before the game can start.
//
// The renderer/runtime half (the rexglue SDK + the recompiled game code) is a separate, much larger job and is not
// in here; `status` reports exactly what each game is still missing.
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "mac_probe.h"
#include "x360fs.h"

namespace fs = std::filesystem;

static const char *kToolVersion = "0.1.0";

// ---- the games ----------------------------------------------------------------------------------------------
// Mirrors games.cpp in the COGBox launcher: the title IDs, the port's program name, and the disc's default.xex the
// port was built from (size + SHA-1). A copy that does not match still runs on Windows with a warning; here we
// report it the same way instead of refusing.
struct GameDef {
  const char *key;
  const char *name;
  const char *dir;      // folder in the COGBox release
  const char *exe;      // the port's program on Windows
  uint32_t title_id;
  uint64_t xex_size;
  const char *xex_sha1;
  const char *year;
};

static const GameDef kGames[] = {
    {"gears1", "Gears of War", "Gears1", "gow1.exe", 0x4D5307D5u, 4767744ull,
     "ee2f204979f9811e99c4e08b70e11de869d005c0", "2006"},
    {"gears2", "Gears of War 2", "Gears2", "gow2.exe", 0x4D53082Du, 18595840ull,
     "b6860bf31e55013467b53eca963d12314c0d78da", "2008"},
    {"gears3", "Gears of War 3", "Gears3", "gow3.exe", 0x4D5308ABu, 21938176ull,
     "2450fd8e4c3cf4d772cd471785d1e38cad3888ad", "2011"},
    {"judgment", "Gears of War: Judgment", "Judgment", "gowj.exe", 0x4D530A26u, 22855680ull,
     "426c5d27ff73d3ff2af9d404adb49e9a3db18bf1", "2013"},
};

static const GameDef *game_by_title(uint32_t tid) {
  for (const auto &g : kGames)
    if (g.title_id == tid) return &g;
  return nullptr;
}

// ---- tiny JSON writer ----------------------------------------------------------------------------------------
static std::string jesc(const std::string &s) {
  std::string o;
  o.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) {
          char b[8];
          std::snprintf(b, sizeof b, "\\u%04x", c);
          o += b;
        } else {
          o += char(c);
        }
    }
  }
  return o;
}
static std::string jstr(const std::string &s) { return "\"" + jesc(s) + "\""; }
// printf takes char*: these keep the call sites readable while the temporary lives to the end of the call.
static const char *cs(const std::string &s) { return s.c_str(); }
static std::string jstr(const char *s) { return s ? jstr(std::string(s)) : "null"; }
static std::string jnum(uint64_t v) { return std::to_string(v); }
static std::string jbool(bool b) { return b ? "true" : "false"; }
static std::string jhex32(uint32_t v) {
  char b[16];
  std::snprintf(b, sizeof b, "0x%08X", v);
  return jstr(b);
}

static std::string human_bytes(uint64_t v) {
  char b[64];
  if (v >= 1ull << 30) std::snprintf(b, sizeof b, "%.1f GB", double(v) / double(1ull << 30));
  else if (v >= 1ull << 20) std::snprintf(b, sizeof b, "%.1f MB", double(v) / double(1ull << 20));
  else if (v >= 1ull << 10) std::snprintf(b, sizeof b, "%.1f KB", double(v) / double(1ull << 10));
  else std::snprintf(b, sizeof b, "%llu B", (unsigned long long)v);
  return b;
}

// ---- what a path is -----------------------------------------------------------------------------------------
struct Identified {
  x360fs::SourceKind kind = x360fs::SourceKind::Unknown;
  fs::path resolved;
  bool has_xex = false;
  x360fs::XexInfo xex;
  bool has_pkg = false;
  x360fs::PackageInfo pkg;
  uint64_t file_count = 0;
  uint64_t total_bytes = 0;
  std::string xex_sha1;
  uint64_t xex_size = 0;
  std::string error;
  const GameDef *game = nullptr;
};

static bool count_entries(const std::vector<x360fs::Entry> &v, uint64_t *files, uint64_t *bytes) {
  *files = *bytes = 0;
  for (const auto &e : v)
    if (!e.is_dir) {
      ++*files;
      *bytes += e.size;
    }
  return true;
}

// Full SHA-1 of default.xex, read out of the image without unpacking the disc. This is the fingerprint COGBox uses
// to decide whether a copy is the one the port was made from.
static bool image_xex_sha1(const fs::path &image, std::string *sha1, uint64_t *size) {
  std::vector<x360fs::Entry> entries;
  std::string err;
  if (!x360fs::list_disc(image, entries, err)) return false;
  for (const auto &e : entries) {
    if (!e.is_dir && e.path == "default.xex") {
      std::vector<uint8_t> buf;
      uint64_t fsz = 0;
      if (!x360fs::image_read_file(image, "default.xex", 0, size_t(e.size), buf, &fsz)) return false;
      if (buf.size() != e.size) return false;
      *sha1 = x360fs::sha1_hex(buf.data(), buf.size());
      if (size) *size = e.size;
      return true;
    }
  }
  return false;
}

static Identified identify(const fs::path &p) {
  Identified id;
  id.resolved = p;
  id.kind = x360fs::detect(p, &id.resolved);
  std::vector<x360fs::Entry> entries;
  std::string err;

  switch (id.kind) {
    case x360fs::SourceKind::DiscImage: {
      id.has_xex = x360fs::disc_xex_info(id.resolved, id.xex);
      if (x360fs::list_disc(id.resolved, entries, err)) count_entries(entries, &id.file_count, &id.total_bytes);
      else id.error = err;
      if (id.has_xex) image_xex_sha1(id.resolved, &id.xex_sha1, &id.xex_size);
      if (!id.has_xex) id.error = "No default.xex in the image's file system.";
      break;
    }
    case x360fs::SourceKind::ExtractedFolder: {
      const fs::path xex = id.resolved / "default.xex";
      id.has_xex = x360fs::read_xex_info(xex, id.xex);
      std::error_code ec;
      if (fs::exists(xex, ec)) {
        id.xex_size = uint64_t(fs::file_size(xex, ec));
        id.xex_sha1 = x360fs::sha1_file(xex);
      }
      for (auto it = fs::recursive_directory_iterator(id.resolved, ec);
           !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        std::error_code e2;
        if (it->is_regular_file(e2)) {
          ++id.file_count;
          id.total_bytes += uint64_t(it->file_size(e2));
        }
      }
      break;
    }
    case x360fs::SourceKind::GodContainer: {
      id.has_pkg = x360fs::read_package_info(id.resolved, id.pkg, err);
      if (!id.has_pkg) id.error = err;
      if (x360fs::list_god(id.resolved, entries, err)) count_entries(entries, &id.file_count, &id.total_bytes);
      break;
    }
    case x360fs::SourceKind::StfsPackage: {
      id.has_pkg = x360fs::read_package_info(id.resolved, id.pkg, err);
      if (!id.has_pkg) id.error = err;
      if (x360fs::list_stfs(id.resolved, entries, err)) count_entries(entries, &id.file_count, &id.total_bytes);
      else if (id.error.empty()) id.error = err;
      break;
    }
    default:
      if (id.error.empty())
        id.error =
            "Not an Xbox 360 game copy COGBox recognises: expected a disc image (.iso), an extracted game folder "
            "(default.xex), a Games on Demand copy, or a title update package.";
  }

  const uint32_t tid = id.has_xex ? id.xex.title_id : (id.has_pkg ? id.pkg.title_id : 0);
  id.game = game_by_title(tid);
  return id;
}

static bool sha_matches(const Identified &id) {
  if (!id.game || id.xex_sha1.empty()) return false;
  return id.xex_sha1 == id.game->xex_sha1 && (!id.xex_size || id.xex_size == id.game->xex_size);
}

static std::string kind_label(x360fs::SourceKind k) {
  switch (k) {
    case x360fs::SourceKind::DiscImage: return "disc image";
    case x360fs::SourceKind::ExtractedFolder: return "extracted folder";
    case x360fs::SourceKind::GodContainer: return "Games on Demand copy";
    case x360fs::SourceKind::StfsPackage: return "package";
    default: return "unknown";
  }
}

// ---- commands -----------------------------------------------------------------------------------------------
static void cmd_doctor(bool json) {
  const MacInfo m = mac_probe();
  if (json) {
    std::string v = "[";
    for (size_t i = 0; i < m.vulkan_libs.size(); ++i) v += (i ? "," : "") + jstr(m.vulkan_libs[i]);
    v += "]";
    std::string o = "{";
    o += "\"tool\":" + jstr(kToolVersion);
    o += ",\"os\":" + jstr(m.os_version);
    o += ",\"machine\":" + jstr(m.machine);
    o += ",\"cpu\":" + jstr(m.cpu_brand);
    o += ",\"cores\":" + std::to_string(m.cores);
    o += ",\"memBytes\":" + std::to_string(m.mem_bytes);
    o += ",\"translated\":" + jbool(m.translated);
    o += ",\"rosetta\":" + jbool(m.rosetta_present);
    o += ",\"avxAdvertised\":" + jbool(m.avx_advertised);
    o += ",\"metal\":" + jbool(m.metal);
    o += ",\"gpu\":" + jstr(m.gpu_name);
    o += ",\"gpuMem\":" + std::to_string(m.gpu_mem);
    o += ",\"gpuUnified\":" + jbool(m.gpu_unified);
    o += ",\"gpuMac2\":" + jbool(m.gpu_mac2);
    o += ",\"vulkanLoaders\":" + v + "}\n";
    std::fputs(o.c_str(), stdout);
    return;
  }
  std::printf("COGBox for macOS %s - host check\n\n", kToolVersion);
  std::printf("  system      macOS %s (%s)\n", m.os_version.c_str(), m.machine.c_str());
  std::printf("  cpu         %s, %d cores, %s\n", m.cpu_brand.c_str(), m.cores, human_bytes(m.mem_bytes).c_str());
  std::printf("  rosetta     %s%s\n", m.rosetta_present ? "installed" : "not installed",
              m.translated ? " (this process is translated)" : "");
  std::printf("  gpu         %s, %s %s\n", m.gpu_name.c_str(), human_bytes(m.gpu_mem).c_str(),
              m.gpu_unified ? "unified memory" : "");
  std::printf("  metal       %s\n", m.metal ? "available" : "MISSING");
  if (m.vulkan_libs.empty())
    std::printf("  vulkan      no loader found (the ports need libvulkan.1.dylib plus the KosmicKrisp ICD)\n");
  else
    for (const auto &p : m.vulkan_libs) std::printf("  vulkan      %s\n", p.c_str());
  std::printf("\n  What this means for COGBox:\n");
  std::printf("   - the launcher's job (read the copy, verify it, unpack it): runs natively here.\n");
  std::printf("   - the port itself needs the rexglue SDK built for macOS and the game recompiled on this machine;\n");
  std::printf("     its renderer runs on Vulkan via the KosmicKrisp driver (LunarG's macOS Vulkan SDK),\n");
  std::printf("     because the D3D12 backend is Windows-only. MoltenVK is not used at run time.\n");
}

static void cmd_probe(const fs::path &p, bool json) {
  const Identified id = identify(p);
  const bool exact = sha_matches(id);
  if (json) {
    std::string g = "null";
    if (id.game) {
      g = "{\"key\":" + jstr(id.game->key) + ",\"name\":" + jstr(id.game->name) + ",\"dir\":" + jstr(id.game->dir) +
          ",\"exe\":" + jstr(id.game->exe) + ",\"titleId\":" + jhex32(id.game->title_id) + ",\"year\":" +
          jstr(id.game->year) + "}";
    }
    std::string x = "null";
    if (id.has_xex) {
      x = "{\"titleId\":" + jhex32(id.xex.title_id) + ",\"version\":" +
          jstr(x360fs::xbox_version_string(id.xex.version)) + ",\"baseVersion\":" +
          jstr(x360fs::xbox_version_string(id.xex.base_version)) + ",\"discNumber\":" + jnum(id.xex.disc_number) +
          ",\"discCount\":" + jnum(id.xex.disc_count) + ",\"size\":" + jnum(id.xex_size) +
          ",\"sha1\":" + (id.xex_sha1.empty() ? std::string("null") : jstr(id.xex_sha1)) +
          ",\"matchesPort\":" + jbool(exact) + "}";
    }
    std::string pk = "null";
    if (id.has_pkg) {
      pk = "{\"magic\":" + jstr(id.pkg.magic) + ",\"titleId\":" + jhex32(id.pkg.title_id) + ",\"version\":" +
           jstr(id.pkg.version_string()) + ",\"baseVersion\":" + jstr(x360fs::xbox_version_string(id.pkg.base_version)) +
           ",\"titleUpdate\":" + jbool(id.pkg.is_title_update()) + ",\"titleName\":" + jstr(id.pkg.title_name) +
           ",\"displayName\":" + jstr(id.pkg.display_name) + "}";
    }
    std::printf(
        "{\"path\":%s,\"resolved\":%s,\"kind\":%s,\"kindLabel\":%s,\"ok\":%s,\"game\":%s,\"xex\":%s,\"package\":%s,"
        "\"files\":%llu,\"bytes\":%llu,\"error\":%s}\n",
        cs(jstr(p.string())), cs(jstr(id.resolved.string())), cs(jstr(x360fs::source_kind_name(id.kind))),
        cs(jstr(kind_label(id.kind))), cs(jbool(id.kind != x360fs::SourceKind::Unknown)), g.c_str(), x.c_str(), pk.c_str(),
        (unsigned long long)id.file_count, (unsigned long long)id.total_bytes,
        cs(id.error.empty() ? std::string("null") : jstr(id.error)));
    return;
  }

  if (id.kind == x360fs::SourceKind::Unknown) {
    std::fprintf(stderr, "%s\n", id.error.c_str());
    std::exit(2);
  }
  std::printf("%s\n", id.resolved.string().c_str());
  std::printf("  kind       %s\n", kind_label(id.kind).c_str());
  if (id.game) std::printf("  game       %s (%s)\n", id.game->name, id.game->year);
  else if (id.has_xex) std::printf("  game       not one of the four COGBox titles (title %08X)\n", id.xex.title_id);
  if (id.has_xex)
    std::printf("  xex        version %s, %s\n", x360fs::xbox_version_string(id.xex.version).c_str(),
                human_bytes(id.xex_size).c_str());
  if (id.has_pkg)
    std::printf("  package    %s%s, version %s%s\n", id.pkg.magic.c_str(),
                id.pkg.is_title_update() ? " (title update)" : "", id.pkg.version_string().c_str(),
                id.pkg.title_name.empty() ? "" : (" - " + id.pkg.title_name).c_str());
  std::printf("  contents   %llu files, %s\n", (unsigned long long)id.file_count, human_bytes(id.total_bytes).c_str());
  if (!id.xex_sha1.empty())
    std::printf("  sha-1      %s%s\n", id.xex_sha1.c_str(),
                exact ? "  [the copy the port is made for]" : "  [not the tested copy - Windows runs it with a warning]");
  if (!id.error.empty()) std::printf("  note       %s\n", id.error.c_str());
}

static void cmd_list(const fs::path &p, bool json) {
  const Identified id = identify(p);
  std::vector<x360fs::Entry> entries;
  std::string err;
  bool ok = false;
  switch (id.kind) {
    case x360fs::SourceKind::DiscImage: ok = x360fs::list_disc(id.resolved, entries, err); break;
    case x360fs::SourceKind::GodContainer: ok = x360fs::list_god(id.resolved, entries, err); break;
    case x360fs::SourceKind::StfsPackage: ok = x360fs::list_stfs(id.resolved, entries, err); break;
    case x360fs::SourceKind::ExtractedFolder: {
      std::error_code ec;
      const fs::path root = id.resolved;
      bool first = true;
      if (json) std::printf("{\"path\":%s,\"entries\":[", cs(jstr(root.string())));
      for (auto it = fs::recursive_directory_iterator(root, ec);
           !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        std::error_code e2;
        const auto rel = fs::relative(it->path(), root, e2);
        if (e2) continue;
        const bool dir = it->is_directory(e2);
        const uint64_t sz = dir ? 0 : uint64_t(it->file_size(e2));
        if (json) {
          std::printf("%s{\"path\":%s,\"size\":%llu,\"dir\":%s}", first ? "" : ",", cs(jstr(rel.string())),
                      (unsigned long long)sz, cs(jbool(dir)));
          first = false;
        } else {
          std::printf("%12s  %s%s\n", dir ? "<dir>" : human_bytes(sz).c_str(), rel.string().c_str(), dir ? "/" : "");
        }
      }
      if (json) std::printf("]}\n");
      return;
    }
    default:
      std::fprintf(stderr, "%s\n", id.error.c_str());
      std::exit(2);
  }
  if (!ok) {
    std::fprintf(stderr, "%s\n", err.c_str());
    std::exit(2);
  }
  if (json) {
    std::printf("{\"path\":%s,\"entries\":[", cs(jstr(id.resolved.string())));
    for (size_t i = 0; i < entries.size(); ++i)
      std::printf("%s{\"path\":%s,\"size\":%llu,\"dir\":%s}", i ? "," : "", cs(jstr(entries[i].path)),
                  (unsigned long long)entries[i].size, cs(jbool(entries[i].is_dir)));
    std::printf("]}\n");
    return;
  }
  for (const auto &e : entries)
    std::printf("%12s  %s%s\n", e.is_dir ? "<dir>" : human_bytes(e.size).c_str(), e.path.c_str(),
                e.is_dir ? "/" : "");
}

// Progress to stderr as one line per update; the app reads these, a terminal shows the percentage.
static void progress_line(bool json, uint64_t done, uint64_t total, const std::string &file) {
  static int last_pct = -1;
  const int pct = total ? int((done * 100) / total) : 0;
  if (json) {
    std::fprintf(stderr, "{\"event\":\"progress\",\"done\":%llu,\"total\":%llu,\"pct\":%d,\"file\":%s}\n",
                 (unsigned long long)done, (unsigned long long)total, pct, jstr(file).c_str());
  } else if (pct != last_pct) {
    std::fprintf(stderr, "\r  %3d%%  %s\033[K", pct, human_bytes(done).c_str());
  }
  last_pct = pct;
}

// Which source tree a game belongs to, and where its title update is mounted when running from the
// tree. Both follow upstream's layout (and port/run_*.sh): Gears 2 / Gears 3 use game/update,
// Judgment reads its update from game/tu4/package.
static fs::path tree_for(const fs::path &repo, const GameDef &g) {
  const std::string key = g.key;
  if (key == "gears2") return repo / "Gears2-Native";
  if (key == "gears3") return repo / "Gears3-Native";
  if (key == "judgment") return repo / "GearsJ-Native";
  return {};
}

static fs::path update_subdir(const GameDef &g) {
  return std::string(g.key) == "judgment" ? fs::path("game/tu4/package") : fs::path("game/update");
}

// The codegen reads <tree>/game/tu6/patched (tu4 for Judgment): the disc's default.xex next to the
// title update's default.xexp, and it applies the patch itself. Installing is the only moment both
// are known to be present, so put them there - the same two files the Windows launcher's
// `build.ps1 -Tu6` copies. Without this a builder who dragged an ISO in could not run `--full`.
static void populate_codegen_input(const fs::path &repo, const GameDef &g, const fs::path &game_root,
                                   bool force) {
  const fs::path tree = tree_for(repo, g);
  std::error_code ec;
  if (tree.empty() || !fs::is_directory(tree, ec)) return;
  const fs::path dst = tree / "game" / (std::string(g.key) == "judgment" ? "tu4" : "tu6") / "patched";
  const fs::path xex = game_root / "game" / "extracted" / "default.xex";
  const fs::path xexp = tree / update_subdir(g) / "default.xexp";
  for (const fs::path &from : {xex, xexp}) {
    if (!fs::is_regular_file(from, ec)) continue;
    const fs::path to = dst / from.filename();
    if (fs::is_regular_file(to, ec) && fs::file_size(to, ec) == fs::file_size(from, ec)) continue;
    // Never quietly replace what is already there: that file may be the copy the tree was built
    // against and is not reproducible from this repository.
    if (fs::is_regular_file(to, ec) && !force) {
      std::fprintf(stderr, "  keeps the existing codegen input %s (pass --force to replace it)\n",
                   to.string().c_str());
      continue;
    }
    fs::create_directories(dst, ec);
    fs::copy_file(from, to, fs::copy_options::overwrite_existing, ec);
    if (!ec) std::fprintf(stderr, "  codegen input: %s\n", to.string().c_str());
  }
}

static int cmd_install(const fs::path &src, const fs::path &repo, bool json, bool force) {
  const Identified id = identify(src);
  if (id.kind == x360fs::SourceKind::Unknown) {
    std::fprintf(stderr, "%s\n", id.error.c_str());
    return 2;
  }
  if (!id.game) {
    std::fprintf(stderr,
                 "This copy is not one of the four COGBox titles (title %08X). COGBox only ships ports for Gears of "
                 "War 1, 2, 3 and Judgment.\n",
                 id.has_xex ? id.xex.title_id : (id.has_pkg ? id.pkg.title_id : 0));
    return 2;
  }

  const bool is_update = id.has_pkg && id.pkg.is_title_update();
  // Where upstream's builders keep it: inside the tree, under game/. .gitignore is what keeps it out
  // of git. Gears 1 has no macOS port, so there is no tree to unpack into.
  std::error_code ec;
  const fs::path tree = tree_for(repo, *id.game);
  if (tree.empty() || !fs::is_directory(tree, ec)) {
    std::fprintf(stderr,
                 "No source tree for %s in %s (Gears 1 has no macOS port).\n", id.game->name, repo.string().c_str());
    return 3;
  }
  const fs::path game_dir = tree / "game";
  const fs::path target = is_update ? tree / update_subdir(*id.game) : game_dir / "extracted";

  if (fs::exists(target, ec) && !force) {
    std::fprintf(stderr, "%s already exists. Pass --force to unpack over it.\n", target.string().c_str());
    return 3;
  }
  fs::create_directories(target, ec);
  if (ec) {
    std::fprintf(stderr, "Could not create %s: %s\n", target.string().c_str(), ec.message().c_str());
    return 3;
  }

  std::atomic<bool> cancel{false};
  auto cb = [json](uint64_t done, uint64_t total, const std::string &file) { progress_line(json, done, total, file); };
  std::string err;
  bool ok = false;
  switch (id.kind) {
    case x360fs::SourceKind::DiscImage:
      ok = x360fs::extract_disc(id.resolved, target, cb, &cancel, err);
      break;
    case x360fs::SourceKind::GodContainer:
      ok = x360fs::extract_god(id.resolved, target, cb, &cancel, err);
      break;
    case x360fs::SourceKind::StfsPackage:
      ok = x360fs::extract_stfs(id.resolved, target, cb, &cancel, err);
      break;
    case x360fs::SourceKind::ExtractedFolder:
      // The player already has the files on disk: point at them instead of copying 7 GB. Nothing to unpack.
      ok = true;
      break;
    default: break;
  }
  if (!json) std::fprintf(stderr, "\n");

  if (!ok) {
    std::fprintf(stderr, "%s\n", err.c_str());
    if (json)
      std::printf("{\"ok\":false,\"error\":%s}\n", jstr(err).c_str());
    return 4;
  }

  // One small manifest per game, kept inside game/ so it is covered by the same ignore rule as the
  // copy it describes. The app and the native ports agree on what was installed from where.
  const fs::path manifest = game_dir / "cogbox-mac.json";
  {
    FILE *f = std::fopen(manifest.string().c_str(), "w");
    if (f) {
      std::fprintf(f,
                   "{\n  \"tool\": \"%s\",\n  \"game\": \"%s\",\n  \"titleId\": \"0x%08X\",\n"
                   "  \"source\": %s,\n  \"kind\": \"%s\",\n  \"installedAs\": \"%s\",\n"
                   "  \"xexSha1\": %s,\n  \"matchesPort\": %s,\n  \"version\": %s\n}\n",
                   kToolVersion, id.game->name, id.game->title_id, jstr(src.string()).c_str(),
                   x360fs::source_kind_name(id.kind), is_update ? "update" : "extracted",
                   id.xex_sha1.empty() ? "null" : jstr(id.xex_sha1).c_str(), cs(jbool(sha_matches(id))),
                   id.has_xex ? jstr(x360fs::xbox_version_string(id.xex.version)).c_str() : "null");
      std::fclose(f);
    }
  }

  populate_codegen_input(repo, *id.game, tree, force);

  if (json) {
    std::string o = "{\"ok\":true,\"game\":" + jstr(id.game->name) + ",\"target\":" + jstr(target.string()) +
                    ",\"part\":" + jstr(is_update ? "update" : "extracted") +
                    ",\"matchesPort\":" + jbool(sha_matches(id)) + "}\n";
    std::fputs(o.c_str(), stdout);
  } else {
    std::printf("%s: %s unpacked into %s\n", id.game->name, is_update ? "title update" : "game", target.c_str());
    if (!sha_matches(id) && !id.xex_sha1.empty())
      std::printf("  note: this is not the exact copy the port was tested with.\n");
  }
  return 0;
}

// What one game needs, read from its own source tree: the copy, its title update, and the built
// program. Upstream's readiness model, with the paths pointing where port/build.sh puts things.
struct GameState {
  bool copy = false, update = false, port = false;
  std::string port_path;
  fs::path root;
};

static GameState game_state(const fs::path &repo, const GameDef &g) {
  GameState s;
  s.root = tree_for(repo, g);
  std::error_code ec;
  if (s.root.empty()) return s;
  s.copy = fs::is_regular_file(s.root / "game" / "extracted" / "default.xex", ec);
  s.update = fs::is_regular_file(s.root / update_subdir(g) / "default.xexp", ec);
  const std::string key = g.key;
  const char *sub = key == "gears2" ? "port/build-patched-tu6"
                    : key == "gears3" ? "port/build-gow3"
                                      : "port/build-gowj";
  // The program's name comes from the game's own exe field ("gowj.exe" -> "gowj"); deriving it from
  // the key letter breaks for Judgment, whose fifth letter is 'm', not 'j'.
  const std::string stem = fs::path(g.exe).stem().string();
  const fs::path exe = repo / sub / stem;
  if (fs::is_regular_file(exe, ec)) {
    s.port = true;
    s.port_path = exe.string();
  }
  return s;
}

static void cmd_status(const fs::path &repo, bool json) {
  if (json) std::fputs(("{\"repo\":" + jstr(repo.string()) + ",\"games\":[").c_str(), stdout);
  else std::printf("Checkout: %s\n\n", repo.string().c_str());

  bool first = true;
  for (const auto &g : kGames) {
    const GameState s = game_state(repo, g);
    const char *state = s.port ? (s.copy && s.update ? "ready" : "needs-copy")
                               : (s.copy ? "no-native-port" : "no-copy");
    if (json) {
      std::string o = (first ? "" : ",") + std::string("{\"key\":") + jstr(g.key) + ",\"name\":" + jstr(g.name) +
                      ",\"copy\":" + jbool(s.copy) + ",\"update\":" + jbool(s.update) + ",\"port\":" +
                      jbool(s.port) + ",\"state\":" + jstr(state) +
                      ",\"portPath\":" + (s.port ? jstr(s.port_path) : std::string("null")) + "}";
      std::fputs(o.c_str(), stdout);
      first = false;
      continue;
    }
    std::printf("  %-24s %s\n", g.name, s.port ? (s.copy && s.update ? "ready" : "program built, copy missing")
                                              : (s.copy ? "copy unpacked, no program built yet" : "no copy yet"));
    std::printf("    %s copy, %s title update, %s program\n", s.copy ? "[x]" : "[ ]",
                s.update ? "[x]" : "[ ]", s.port ? "[x]" : "[ ]");
  }
  if (json) std::printf("]}\n");
}

// ---- languages (COGBox's own launcher has had these since 0.2.0) ------------------------------------------------
// Windows: cogbox/src/i18n.cpp translates the launcher, and cogbox/src/play.cpp passes --cogbox_ui_lang so the
// ports' in-game menu / Achievements page / popups use the same lang/<code>.txt file. macOS has no Win32 launcher,
// so this tool is the one that has to make that choice and pass it on.
struct UiLang { const char* code, *name; };
static const UiLang kUiLangs[] = {
    {"en", "English"}, {"es", "Espanol"}, {"fr", "Francais"}, {"de", "Deutsch"}, {"it", "Italiano"},
    {"pt-BR", "Portugues (Brasil)"}, {"pl", "Polski"}, {"hu", "Magyar"}, {"ru", "Russkij"},
    {"ja", "Nihongo"}, {"zh-Hans", "Jianti Zhongwen"}, {"ko", "Hangugeo"},
};
static bool valid_lang(const std::string& c) {
  if (c == "auto") return true;
  for (const auto& l : kUiLangs) if (c == l.code) return true;
  return false;
}
// The Mac's first preferred language ("zh-Hans-CN", "en-CN", ...). `defaults` is a small system utility; the GUI
// resolves Locale.preferredLanguages itself and passes an explicit code, so this is the direct-CLI fallback.
static std::string mac_preferred_language() {
  FILE* p = popen("/usr/bin/defaults read -g AppleLanguages 2>/dev/null", "r");
  if (!p) return {};
  char buf[4096] = {};
  const size_t n = fread(buf, 1, sizeof(buf) - 1, p);
  pclose(p);
  buf[n] = 0;
  const std::string s(buf);
  const size_t q = s.find('"');
  if (q == std::string::npos) return {};
  const size_t e = s.find('"', q + 1);
  return e == std::string::npos ? std::string() : s.substr(q + 1, e - q - 1);
}
static std::string lang_from_locale(std::string l) {
  for (auto& c : l) {
    c = char(std::tolower(static_cast<unsigned char>(c)));
    if (c == '_') c = '-';
  }
  if (l.rfind("zh-hans", 0) == 0 || l.rfind("zh-cn", 0) == 0 || l.rfind("zh-chs", 0) == 0 || l == "zh")
    return "zh-Hans";
  if (l.rfind("pt-br", 0) == 0 || l == "pt") return "pt-BR";
  for (const char* c : {"es", "fr", "de", "it", "pl", "hu", "ru", "ja", "ko"})
    if (l == c || l.rfind(std::string(c) + "-", 0) == 0) return c;
  return "en";  // English, or a locale with no COGBox translation
}
static std::string resolve_lang(const std::string& choice) {
  if (choice != "auto" && !choice.empty()) return choice;
  std::string s;
  if (const char* e = std::getenv("COGBOX_LANG")) s = e;
  if (s.empty()) s = mac_preferred_language();
  if (s.empty())
    for (const char* v : {"LANG", "LC_ALL", "LC_MESSAGES"})
      if (const char* e = std::getenv(v)) { s = e; break; }
  return lang_from_locale(s);
}
// ui_lang.cpp reads <cogbox_dir>/lang/<code>.txt; with cogbox_dir unset (the scripts never set it) that is
// <cwd>/lang/<code>.txt. Point each game folder's lang/ at the one shared set of translations in the sources.
// All three ports share one set of COGBox translations, kept in the Gears 2 source tree.
static fs::path shared_lang_dir(const fs::path& repo) {
  const fs::path p = repo / "Gears2-Native" / "cogbox" / "lang";
  std::error_code ec;
  return fs::is_directory(p, ec) ? p : fs::path{};
}
static fs::path ensure_lang_link(const fs::path& cwd, const fs::path& shared, bool create) {
  const fs::path link = cwd / "lang";
  std::error_code ec;
  if (fs::is_symlink(link, ec)) {
    if (fs::is_directory(link, ec)) return link;  // still resolves
    if (create) { fs::remove(link, ec); fs::create_directory_symlink(shared, link, ec); }
  } else if (fs::is_directory(link, ec)) {
    return link;  // a real folder wins
  } else if (create && !fs::exists(link, ec)) {
    fs::create_directory_symlink(shared, link, ec);
  }
  return link;
}

// ---- play --native: start the port built for this Mac -----------------------------------------------------------
// port/run_gow2.sh / run_gowj.sh / run_gow3.sh used to be the only way to start the games. COGBox's front end (and
// this command) now own that job: the executable, its working directory, the KosmicKrisp ICD and every launcher
// argument live here, mirrored from those scripts, so starting a game never needs a shell script.
struct NativeLaunch {
  std::string exe, cwd;
  std::vector<std::string> args;
};

static fs::path resolve_icd(const fs::path &repo);  // defined with the play command below

// dxc is a stub that loads @rpath/libdxcompiler.dylib, and port/third_party/ is not tracked: it is easy to
// end up with the stub but not the library, and then every built-in shader (rectangle lists, resolves, the
// present blit) fails to compile and a cold shader cache never renders a frame - which looks like a hang in
// the startup movies. Take the first dxc that actually runs: the port's own, $VULKAN_SDK, then the SDK the
// ICD came from.
static bool dxc_runs(const fs::path &dir) {
  std::error_code ec;
  if (!fs::is_regular_file(dir / "dxc", ec)) return false;
  const std::string cmd = "( \"" + (dir / "dxc").string() + "\" --version >/dev/null 2>&1 ) 2>/dev/null";
  return std::system(cmd.c_str()) == 0;
}

static fs::path resolve_dxc(const fs::path &repo, const fs::path &icd) {
  std::vector<fs::path> candidates{repo / "port/third_party/dxc-macos/bin"};
  if (const char *sdk = std::getenv("VULKAN_SDK")) candidates.push_back(fs::path(sdk) / "bin");
  fs::path sdk_root = icd;  // <sdk>/macOS/share/vulkan/icd.d/<name>.json -> <sdk>/macOS
  for (int i = 0; i < 4; ++i) sdk_root = sdk_root.parent_path();
  if (!sdk_root.empty()) candidates.push_back(sdk_root / "bin");
  for (const fs::path &c : candidates)
    if (dxc_runs(c)) return c;
  return candidates.front();
}

static NativeLaunch native_launch(const fs::path &repo, const std::string &key) {
  NativeLaunch n;
  const std::string dxc = resolve_dxc(repo, resolve_icd(repo)).string();
  if (key == "gears2") {
    n.exe = (repo / "port/build-patched-tu6/gow2").string();
    n.cwd = (repo / "Gears2-Native").string();
    n.args = {"--game_data_root=game/extracted",
              "--user_data_root=user",
              "--update_data_root=game/update",
              "--log_file=logs/gow2.log",
              "--gow2_crash_dir=logs",
              "--gpu_plugin=xenos",
              "--gow2_shader_cache_dir=shadercache",
              "--gow2_dxc_dir=" + dxc,
              "--host_present_from_non_ui_thread=false",
              // Gears 2: the EDRAM ownership workaround verified on the title screen (see port/run_gow2.sh).
              "--gow2_renderer_fill_ownership=false",
              // Gears 2 waits for every second vertical blank (30 Hz on a 60 Hz display), so presenting in
              // FIFO mode caps it at 30 no matter the hardware. Off = the emulated vblank runs at 1000 Hz.
              // The launcher's V-Sync control overrides this with --gow2_gpu_vsync=true.
              "--gow2_gpu_vsync=false",
              "--mnk_mode=true",
              "--mnk_mouse=true",
              "--mnk_sensitivity=1.0",
              "--keybind_a=Space",
              "--keybind_b=F",
              "--keybind_x=E",
              "--keybind_y=Q",
              "--keybind_right_trigger=LMB",
              "--keybind_left_trigger=RMB",
              "--keybind_right_shoulder=R",
              "--keybind_left_shoulder=Tab",
              "--keybind_dpad_left=1",
              "--keybind_dpad_right=2",
              "--keybind_dpad_up=3",
              "--keybind_dpad_down=4",
              "--keybind_rstick_press=MMB,Z",
              "--keybind_lstick_press=C",
              "--keybind_start=Escape,Return",
              "--keybind_back=Backspace"};
  } else if (key == "judgment") {
    n.exe = (repo / "port/build-gowj/gowj").string();
    n.cwd = (repo / "GearsJ-Native").string();
    n.args = {"--game_data_root=game/extracted",
              "--update_data_root=game/tu4/package",
              "--user_data_root=out/userdata",
              "--log_file=out/play-logs/gowj.log",
              "--gow2_crash_dir=out/play-logs",
              "--gpu_plugin=xenos",
              "--gow2_shader_cache_dir=out/userdata/cache",
              "--gow2_dxc_dir=" + dxc,
              "--host_present_from_non_ui_thread=false",
              "--mnk_mode=true",
              "--mnk_mouse=true"};
  } else if (key == "gears3") {
    n.exe = (repo / "port/build-gow3/gow3").string();
    n.cwd = (repo / "Gears3-Native").string();
    n.args = {"--game_data_root=game/extracted",
              "--update_data_root=game/update",
              "--user_data_root=out/userdata",
              "--log_file=out/play-logs/gow3.log",
              "--gow2_crash_dir=out/play-logs",
              "--gpu_plugin=xenos",
              "--gow2_shader_cache_dir=out/userdata/cache",
              "--gow2_dxc_dir=" + dxc,
              "--host_present_from_non_ui_thread=false",
              "--mnk_mode=true",
              "--mnk_mouse=true"};
  }
  return n;
}

// ---- settings: --set / --extra-args ----------------------------------------------------------------------------
// COGBox for Windows turns ~60 UI boxes into command-line switches (gears_settings.cpp::build_args). This port does
// not have that settings UI, so it exposes the same switches directly: --set replaces/ adds one, and --extra-args
// reads a file of raw switches (out/extra-args.txt in the Windows launcher: one per line, # comments, {LOG}).
// Defaults are left alone - with no --set / --extra-args the argv is byte-for-byte the old run_*.sh argument list.
static std::string trim_line(std::string t) {
  const size_t a = t.find_first_not_of(" \t\r\n"), b = t.find_last_not_of(" \t\r\n");
  return a == std::string::npos ? std::string() : t.substr(a, b - a + 1);
}
static bool valid_set_arg(const std::string& v) {
  if (v.rfind("--", 0) != 0 || v.size() < 4) return false;
  const size_t eq = v.find('=');
  const std::string name = v.substr(2, eq == std::string::npos ? std::string::npos : eq - 2);
  if (name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") != std::string::npos)
    return false;
  return v.find('\n') == std::string::npos && v.find('\r') == std::string::npos;
}
static void apply_set(std::vector<std::string>& argv, std::string v) {
  if (v.rfind("--", 0) != 0) v = "--" + v;
  const size_t eq = v.find('=');
  const std::string key = eq == std::string::npos ? v : v.substr(0, eq);
  // An empty value removes a switch the native launch sets by default. COGBox for Windows does the same
  // for "Disc (original release)": without --update_data_root the game reads the disc data only.
  if (eq != std::string::npos && eq + 1 == v.size()) {
    argv.erase(std::remove_if(argv.begin(), argv.end(),
                              [&](const std::string& a) { return a == key || a.rfind(key + "=", 0) == 0; }),
               argv.end());
    return;
  }
  for (auto& a : argv)
    if (a == key || a.rfind(key + "=", 0) == 0) { a = v; return; }
  argv.push_back(v);
}
static std::vector<std::string> read_extra_args(const fs::path& file, const std::string& log_dir) {
  std::vector<std::string> out;
  std::ifstream in(file);
  std::string raw;
  while (std::getline(in, raw)) {
    std::string l = trim_line(raw);
    if (l.empty() || l[0] == '#') continue;
    for (size_t at = 0; (at = l.find("{LOG}", at)) != std::string::npos; at += log_dir.size())
      l.replace(at, 5, log_dir);
    out.push_back(l);
  }
  return out;
}

// Where the KosmicKrisp ICD is. The Vulkan SDK is a prerequisite, not something this repository
// ships or downloads, so look for it in the usual places: this checkout's tools/VulkanSDK (what the
// run scripts use), then $VULKAN_SDK, then the installer's default ~/VulkanSDK/<version>/macOS.
static fs::path resolve_icd(const fs::path &repo) {
  const char *rel = "share/vulkan/icd.d/libkosmickrisp_icd.json";
  std::error_code ec;
  const fs::path local = repo / "tools/VulkanSDK/macOS" / rel;
  if (fs::is_regular_file(local, ec)) return local;
  if (const char *env = std::getenv("VULKAN_SDK")) {
    const fs::path p = fs::path(env) / rel;
    if (fs::is_regular_file(p, ec)) return p;
  }
  if (const char *home = std::getenv("HOME")) {
    // The installer writes ~/VulkanSDK/<version>/macOS by default, but a root of ~/VulkanSDK itself
    // gives ~/VulkanSDK/macOS - accept both. When several versions are installed the newest wins:
    // plain directory order would rank "1.4.9" above "1.4.363".
    const fs::path root = fs::path(home) / "VulkanSDK";
    const fs::path plain = root / "macOS" / rel;
    if (fs::is_regular_file(plain, ec)) return plain;
    auto parts = [](const std::string &v) {
      std::vector<long> out;
      std::string cur;
      for (char c : v + ".") {
        if (c == '.') { out.push_back(cur.empty() ? 0 : std::strtol(cur.c_str(), nullptr, 10)); cur.clear(); }
        else cur.push_back(c);
      }
      return out;
    };
    auto older = [](const std::vector<long> &a, const std::vector<long> &b) {
      for (size_t i = 0; i < std::max(a.size(), b.size()); ++i) {
        const long x = i < a.size() ? a[i] : 0, y = i < b.size() ? b[i] : 0;
        if (x != y) return x < y;
      }
      return false;
    };
    fs::path best;
    std::vector<long> best_version;
    for (fs::directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec)) {
      const fs::path candidate = it->path() / "macOS" / rel;
      if (!fs::is_regular_file(candidate, ec)) continue;
      const std::vector<long> version = parts(it->path().filename().string());
      if (best.empty() || older(best_version, version)) { best = candidate; best_version = version; }
    }
    if (!best.empty()) return best;
  }
  return local;
}

static int cmd_play_native(const fs::path &repo, const std::string &key, const std::string &lang_choice,
                           const std::vector<std::string> &set_args, const fs::path &extra_file,
                           bool dry_run, bool json) {
  NativeLaunch n = native_launch(repo, key);
  const std::string lang = resolve_lang(lang_choice);
  const fs::path shared_lang = shared_lang_dir(repo);
  std::error_code ec;
  const fs::path icd = resolve_icd(repo);
  const char *msg = nullptr;
  if (n.exe.empty()) msg = "There is no native macOS build for this game yet (Gears 1 is not ported).";
  else if (!fs::is_regular_file(n.exe, ec)) msg = "The native port executable is missing; build it first.";
  else if (!fs::is_directory(n.cwd, ec)) msg = "The game data folder for this port is missing.";
  else if (!fs::is_regular_file(icd, ec))
    msg = "The KosmicKrisp Vulkan ICD was not found. Install the LunarG macOS Vulkan SDK (see README).";
  if (msg) {
    if (json) std::printf("{\"ok\":false,\"dryRun\":%s,\"game\":%s,\"error\":%s}\n",
                          dry_run ? "true" : "false", cs(jstr(key)), cs(jstr(msg)));
    else std::fprintf(stderr, "%s\n", msg);
    return 5;
  }

  // The launchers create these before exec; do the same so a first run has somewhere to write.
  if (key == "gears2") {
    fs::create_directories(fs::path(n.cwd) / "user", ec);
    fs::create_directories(fs::path(n.cwd) / "logs", ec);
    fs::create_directories(fs::path(n.cwd) / "shadercache", ec);
  } else {
    fs::create_directories(fs::path(n.cwd) / "out/userdata/cache", ec);
    fs::create_directories(fs::path(n.cwd) / "out/play-logs", ec);
  }

  // The data lives in the tree, under game/ - the paths native_launch() passes are already relative
  // to it, so nothing needs rewriting here. This only records the readiness the front end shows.
  fs::path data_root, upd_root;
  if (fs::is_regular_file(fs::path(n.cwd) / "game" / "extracted" / "default.xex", ec)) {
    data_root = fs::path("game") / "extracted";
    upd_root = key == "judgment" ? fs::path("game") / "tu4" / "package" : fs::path("game") / "update";
  }
  const fs::path upd_abs = upd_root.empty() ? fs::path() : fs::path(n.cwd) / upd_root;

  // The front end shows the same three-step readiness as COGBox's launcher.
  const bool has_data = !data_root.empty();
  const bool needs_update = true;  // every port is built against its title update (Gears 3's codegen is TU6 too)
  const bool has_update = !needs_update || fs::is_regular_file(upd_abs / "default.xexp", ec) ||
                          fs::is_directory(upd_abs, ec);

  std::vector<std::string> argv{n.exe};
  for (const auto &a : n.args) argv.push_back(a);
  // COGBox's own in-game text (settings menu, Achievements, popups) in the chosen language. English needs no
  // option - the ports ship English strings. The game's own localisation is a separate switch: with SDK
  // patch 45 applied, XGetLanguage answers with --user_language, which the Gameplay > Game language
  // setting sends through --set. This --lang option only carries --cogbox_ui_lang.
  const fs::path lang_link = ensure_lang_link(fs::path(n.cwd), shared_lang, !dry_run);
  const fs::path lang_file = lang_link / (lang + ".txt");
  std::error_code lang_ec;
  const bool lang_available = lang == "en" || (!shared_lang.empty() &&
                                              fs::is_regular_file(shared_lang / (lang + ".txt"), lang_ec));
  if (lang != "en" && lang_available) argv.push_back("--cogbox_ui_lang=" + lang);
  for (const auto& v : set_args) apply_set(argv, v);
  const std::string log_dir = key == "gears2" ? "logs" : "out/play-logs";
  const std::vector<std::string> extra_lines = extra_file.empty() ? std::vector<std::string>{}
                                                                  : read_extra_args(extra_file, log_dir);
  for (const auto& l : extra_lines) argv.push_back(l);
  const std::string dyld = (repo / "port/sdk-patched-cg/out/mac-arm64").string() + ":" +
                           (repo / "port/sdk/lib").string();

  if (json || dry_run) {
    std::string o = "{\"ok\":true,\"dryRun\":" + std::string(dry_run ? "true" : "false") +
                    ",\"game\":" + cs(jstr(key)) + ",\"exe\":" + cs(jstr(n.exe)) +
                    ",\"cwd\":" + cs(jstr(n.cwd)) + ",\"icd\":" + cs(jstr(icd.string())) +
                    ",\"dyld\":" + cs(jstr(dyld)) + ",\"lang\":" + cs(jstr(lang)) +
                    ",\"langFile\":" + cs(jstr(lang_file.string())) + ",\"langAvailable\":" + jbool(lang_available) +
                    ",\"sets\":" + std::to_string(set_args.size()) +
                    ",\"extraArgs\":" + std::to_string(extra_lines.size()) +
                    ",\"extraArgsFile\":" + cs(jstr(extra_file.string())) +
                    ",\"data\":" + jbool(has_data) +
                    ",\"update\":" + jbool(has_update) + ",\"needsUpdate\":" + jbool(needs_update) + ",\"argv\":[";
    for (size_t i = 0; i < argv.size(); ++i) {
      if (i) o += ",";
      o += jstr(argv[i]);
    }
    o += "]}";
    std::printf("%s\n", cs(o));
  }
  if (dry_run) return 0;

  pid_t pid = fork();
  if (pid == 0) {
    setenv("VK_DRIVER_FILES", icd.string().c_str(), 1);
    setenv("DYLD_LIBRARY_PATH", dyld.c_str(), 1);
    unsetenv("VK_ICD_FILENAMES");
    if (chdir(n.cwd.c_str()) != 0) {
      std::perror("could not enter the game folder");
      _exit(127);
    }
    std::vector<char *> cargv;
    for (auto &a : argv) cargv.push_back(const_cast<char *>(a.c_str()));
    cargv.push_back(nullptr);
    execv(cargv[0], cargv.data());
    std::perror("could not start the native port");
    _exit(127);
  }
  if (pid < 0) {
    std::fprintf(stderr, "could not fork: %s\n", std::strerror(errno));
    return 5;
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

// ---- port: how far the native macOS build has got -----------------------------------------------------------
#ifndef COGBOX_SOURCE_DIR
#define COGBOX_SOURCE_DIR "."
#endif

static bool file_exists(const fs::path &p) {
  std::error_code ec;
  return fs::is_regular_file(p, ec);
}
static bool dir_exists(const fs::path &p) {
  std::error_code ec;
  return fs::is_directory(p, ec);
}

static int cmd_port(bool json) {
  const fs::path root = COGBOX_SOURCE_DIR;
  const fs::path port = root / "port";
  // Gears2-Native/ is a real subdirectory of this repository (the fork clone), not a link under port/.
  const fs::path tree = root / "Gears2-Native";

  struct Item {
    std::string key, label, detail;
    bool ok;
    bool optional = false;   // missing is fine: shown as "-" instead of a blank
  };
  std::vector<Item> items;

  // 1. rexglue SDK (an install prefix with lib/cmake/rexglue/rexglueConfig.cmake)
  fs::path sdk;
  for (const char *env : {"REXSDK_DIR", "REXSDK_PREFIX"}) {
    const char *v = std::getenv(env);
    if (v && *v && file_exists(fs::path(v) / "lib" / "cmake" / "rexglue" / "rexglueConfig.cmake")) {
      sdk = v;
      break;
    }
  }
  if (sdk.empty()) {
    for (const fs::path &cand : {port / "sdk", fs::path("/opt/rexglue-sdk"), fs::path("/usr/local/rexglue-sdk")}) {
      if (file_exists(cand / "lib" / "cmake" / "rexglue" / "rexglueConfig.cmake")) {
        sdk = cand;
        break;
      }
    }
  }
  items.push_back({"sdk", "rexglue SDK for macOS", sdk.empty() ? "not found - set REXSDK_DIR" : sdk.string(),
                   !sdk.empty()});

  // 2. Vulkan headers
  fs::path vk;
  for (const fs::path &cand : {port / "third_party" / "vulkan-headers" / "include", fs::path("/opt/homebrew/include"),
                               fs::path("/usr/local/include")}) {
    if (file_exists(cand / "vulkan" / "vulkan_core.h")) {
      vk = cand;
      break;
    }
  }
  items.push_back({"vulkan-headers", "Vulkan 头文件", vk.empty() ? "not found" : vk.string(), !vk.empty()});

  // 3. Vulkan loader (from the release SDK) + the KosmicKrisp ICD the ports actually run on.
  fs::path loader;
  for (const fs::path &cand : {sdk / "lib" / "libvulkan.1.dylib", port / "sdk" / "lib" / "libvulkan.1.dylib",
                               fs::path("/opt/homebrew/lib/libvulkan.1.dylib"),
                               fs::path("/usr/local/lib/libvulkan.1.dylib")}) {
    if (!cand.empty() && file_exists(cand)) {
      loader = cand;
      break;
    }
  }
  items.push_back({"vulkan-loader", "Vulkan 加载器",
                   loader.empty() ? "not found - unpack the rexglue release SDK into port/sdk/" : loader.string(),
                   !loader.empty()});

  const fs::path icd = resolve_icd(root);
  items.push_back({"kosmic-krisp", "KosmicKrisp ICD (运行时驱动)",
                   file_exists(icd) ? icd.string()
                                    : "not found - install the LunarG macOS Vulkan SDK (see README)",
                   file_exists(icd)});

  // 4. DXC: optional, only the slower `hlsl` shader backend needs it
  fs::path dxc;
  for (const char *cand : {"/opt/homebrew/lib/libdxcompiler.dylib", "/usr/local/lib/libdxcompiler.dylib"}) {
    if (file_exists(cand)) {
      dxc = cand;
      break;
    }
  }
  // dxc is required: the renderer's built-in shaders (rectangle lists, resolves, the present blit) are HLSL
  // compiled at run time. A dxc that cannot load libdxcompiler.dylib fails silently - every one of those
  // shaders then fails, and a cold shader cache never renders a frame.
  const fs::path dxc_dir = resolve_dxc(root, resolve_icd(root));
  const bool dxc_ok = dxc_runs(dxc_dir);
  items.push_back({"dxc", "DXC（编译内置着色器，必需）",
                   dxc_ok ? (dxc_dir / "dxc").string()
                          : "not found - unpack dxc with its libdxcompiler.dylib, or install the Vulkan SDK",
                   dxc_ok});

  // 5. the patched tree
  bool tree_ok = file_exists(tree / "CMakeLists.txt");
  items.push_back({"tree", "打好补丁的源码树", tree_ok ? tree.string() : "run port/patch.py", tree_ok});

  // 6. build output
  const fs::path lib = port / "build" / "libgn_layer0_xenos.a";
  const fs::path exe = port / "build-patched" / "gow2";
  std::error_code ec;
  const bool built = file_exists(lib);
  std::string build_detail = "not built";
  if (built) build_detail = human_bytes(uint64_t(fs::file_size(lib, ec)));
  else {
    // Partial progress is the interesting number while the port is being brought up: count what compiled.
    int objects = 0;
    std::error_code e2;
    const fs::path dir = port / "build" / "CMakeFiles" / "gn_layer0_xenos.dir";
    if (dir_exists(dir))
      for (auto it = fs::recursive_directory_iterator(dir, e2);
           !e2 && it != fs::recursive_directory_iterator(); it.increment(e2))
        if (it->path().extension() == ".o") ++objects;
    if (objects) build_detail = std::to_string(objects) + " objects compiled, not linked yet";
  }
  items.push_back({"layer0", "layer 0 静态库", build_detail, built});
  items.push_back({"gow2", "游戏程序 gow2", file_exists(exe) ? "present" : "not built", file_exists(exe)});
  const bool vktest = file_exists(port / "build" / "gn_vktest");
  items.push_back({"vktest", "Vulkan 后端自测（无游戏）",
                   vktest ? "built - run port/run_vktest.sh" : "not built", vktest});

  // The SDK built from source with COGBox's patch. This is what the renderer takeover needs: the
  // released library exports no rex::graphics::DrawObserver at all.
  const fs::path patched_sdk_lib = port / "sdk-patched-cg" / "out" / "mac-arm64" / "librexruntimerd.dylib";
  const bool patched_sdk = file_exists(patched_sdk_lib);
  items.push_back({"sdk-src", "自建 SDK（带 COGBox 的补丁）",
                   patched_sdk ? patched_sdk_lib.string()
                               : "not built - run: cd port && ./build_sdk.sh",
                   patched_sdk});

  // layer 0 compiled against that SDK. Separate from `layer0` because the released SDK stops in
  // shadow_renderer.cpp - the two builds answer different questions.
  const fs::path patched_lib = port / "build-patched" / "libgn_layer0_xenos.a";
  const bool patched_built = file_exists(patched_lib);
  std::string patched_detail = "not built";
  if (patched_built) patched_detail = human_bytes(uint64_t(fs::file_size(patched_lib, ec)));
  else {
    int objects = 0;
    std::error_code e3;
    const fs::path dir = port / "build-patched" / "CMakeFiles" / "gn_layer0_xenos.dir";
    if (dir_exists(dir))
      for (auto it = fs::recursive_directory_iterator(dir, e3);
           !e3 && it != fs::recursive_directory_iterator(); it.increment(e3))
        if (it->path().extension() == ".o") ++objects;
    if (objects) patched_detail = std::to_string(objects) + " objects compiled, not linked yet";
  }
  items.push_back({"layer0-patched", "layer 0（对自建 SDK 编译，含渲染器接管）", patched_detail, patched_built});

  // The recompiler CLI. Its presence is what separates "layer 0 builds" from "a game program can
  // be produced"; running it still needs the player's own disc image.
  const fs::path rexglue_bin = port / "sdk-patched-cg" / "out" / "mac-arm64" / "rexgluerd";
  const bool has_rexglue = file_exists(rexglue_bin);
  items.push_back({"codegen", "重编译器 CLI（codegen）",
                   has_rexglue ? rexglue_bin.string() : "not built - SDK_SKIP_CODEGEN is not set by default; rebuild the SDK",
                   has_rexglue});

  // 7. the game copy codegen needs
  std::vector<fs::path> game_candidates = {tree / "game" / "extracted" / "default.xex",
                                           tree / "game" / "tu6" / "patched" / "default.xex",
                                           tree / "game" / "disc" / "default.xex"};
  const char *home = std::getenv("HOME");
  if (home) game_candidates.push_back(fs::path(home) / "Games" / "COGBox" / "Gears2" / "game" / "extracted" /
                                      "default.xex");
  fs::path game;
  for (const auto &cand : game_candidates)
    if (file_exists(cand)) {
      game = cand;
      break;
    }
  items.push_back({"game", "你自己的游戏副本（codegen 的输入）", game.empty() ? "not found" : game.string(),
                   !game.empty()});

  // What the port actually needs next, not just "build something".
  std::string next;
  if (sdk.empty() || vk.empty() || loader.empty() || !file_exists(icd))
    next = "install what is missing above (release SDK, Vulkan headers/loader, KosmicKrisp ICD), "
           "then run: cd port && ./build.sh";
  else if (!patched_sdk)
    next = "cd port && ./build_sdk.sh   "
           "(builds the SDK with COGBox's patch; sdk-src comes from a git clone of the rexglue SDK)";
  else if (!patched_built)
    next = "cd port && ./build.sh --patched   (layer 0 against the self-built SDK)";
  else if (game.empty())
    next = "everything that can be built without the game is built. Put your own disc image and title "
           "update where the manifest expects them (Gears2-Native/game/extracted/default.xex), "
           "then: cd port && ./build.sh --patched --full";
  else
    next = "everything is built - run: cd port && ./run_gow2.sh   (a window opens; whether the picture is "
           "right is not verified yet)";

  if (json) {
    std::string o = "{\"next\":" + jstr(next) + ",\"items\":[";
    for (size_t i = 0; i < items.size(); ++i)
      o += (i ? "," : "") + std::string("{\"key\":") + jstr(items[i].key) + ",\"label\":" + jstr(items[i].label) +
           ",\"detail\":" + jstr(items[i].detail) + ",\"ok\":" + jbool(items[i].ok) +
           ",\"optional\":" + jbool(items[i].optional) + "}";
    o += "]}";
    std::printf("%s\n", cs(o));
    return 0;
  }

  std::printf("COGBox 原生 macOS 移植 - 自检\n\n");
  for (const auto &it : items)
    std::printf("  [%s] %s \xE2\x80\x94 %s\n", it.ok ? "x" : (it.optional ? "-" : " "), it.label.c_str(),
                it.detail.c_str());
  std::printf("\n  下一步: %s\n", next.c_str());
  if (built)
    std::printf("  提示: `port/run_vktest.sh` 会在这台 Mac 的 GPU 上跑 90 项 Vulkan 检查\n");
  return 0;
}

// ---- entry --------------------------------------------------------------------------------------------------
static void usage() {
  std::printf(
      "COGBox for macOS %s - recognise and unpack your own Xbox 360 Gears of War copies\n\n"
      "  cogbox-mac doctor                     check this Mac (GPU, Metal, Vulkan, Rosetta)\n"
      "  cogbox-mac probe <path> [--json]      what is this file/folder, and is it the tested copy?\n"
      "  cogbox-mac list <path> [--json]       list the files inside a copy\n"
      "  cogbox-mac install <path> [--force] [--json]\n"
      "                                        unpack into the game's own tree, under game/\n"
      "  cogbox-mac status [--json]            what each game still needs (copy, title update, program)\n"
      "  cogbox-mac port [--json]              native macOS build: what is in place, what is missing\n"
      "  cogbox-mac play [--game <key>] [--repo <dir>] [--lang <code|auto>]\n"
      "                  [--set <name>=<value>]... [--extra-args <file>] [--dry-run] [--json]\n"
      "                                        start the native macOS port built in this repo (Gears 2/3/Judgment),\n"
      "                                        with the KosmicKrisp ICD and the same arguments as run_*.sh.\n"
      "                                        --lang (default auto = this Mac's language) also translates the\n"
      "                                        ports' in-game COGBox menu/achievement text (12 languages).\n"
      "                                        --set overrides one launch switch, --extra-args reads a file of\n"
      "                                        extra switches (one per line, # comments, {LOG} = the log folder)\n\n"
      "<path> is a disc image (.iso), an extracted game folder, a Games on Demand folder (or its header file),\n"
      "or a title update package. No game data is included in this tool: you need your own copy.\n",
      kToolVersion);
}

// Where is the checkout? Not a fixed path: the fork can be cloned anywhere, and the CLI runs from
// <repo>/build/ while the app runs from <repo>/build/COGBox.app/Contents/MacOS/. Walk up from the
// executable (then the cwd) looking for the port/ + Gears2-Native/ pair that identifies the repo,
// and only then fall back to the conventional clone location. --repo always overrides this.
static bool looks_like_repo(const fs::path& p) {
  std::error_code ec;
  return fs::is_directory(p / "port", ec) && fs::is_directory(p / "Gears2-Native", ec);
}
static fs::path find_repo_from(fs::path p) {
  std::error_code ec;
  if (p.empty()) return {};
  if (!p.is_absolute()) p = fs::absolute(p, ec);
  if (!fs::is_directory(p, ec)) p = p.parent_path();
  for (int i = 0; i < 12 && !p.empty(); ++i) {
    if (looks_like_repo(p)) return p.lexically_normal();
    const fs::path parent = p.parent_path();
    if (parent == p) break;
    p = parent;
  }
  return {};
}
static fs::path default_repo(const char* home, const char* argv0) {
  fs::path r = find_repo_from(argv0 ? fs::path(argv0) : fs::path());
  if (r.empty()) {
    std::error_code ec;
    r = find_repo_from(fs::current_path(ec));
  }
  if (r.empty() && home) {
    for (const fs::path& c : {fs::path(home) / "Games" / "cogbox", fs::path(home) / "Games"})
      if (looks_like_repo(c)) { r = c; break; }
  }
  if (r.empty()) r = home ? fs::path(home) / "Games" / "cogbox" : fs::path(".");
  return r;
}

int main(int argc, char **argv) {
  std::vector<std::string> args(argv + 1, argv + argc);
  if (args.empty()) {
    usage();
    return 0;
  }
  bool json = false;
  bool force = false;
  bool dry_run = false;
  std::string game_key, lang_choice = "auto";
  std::vector<std::string> set_args;
  fs::path repo, extra_file;
  std::vector<std::string> pos;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string &a = args[i];
    if (a == "--json") json = true;
    else if (a == "--force") force = true;
    else if (a == "--dry-run") dry_run = true;
    else if (a == "--native") { /* accepted and ignored: every port here is native */ }
    else if (a == "--repo" && i + 1 < args.size()) repo = args[++i];
    else if (a == "--lang" && i + 1 < args.size()) lang_choice = args[++i];
    else if (a == "--set" && i + 1 < args.size()) set_args.push_back(args[++i]);
    else if (a == "--extra-args" && i + 1 < args.size()) extra_file = args[++i];
    else if (a == "--game" && i + 1 < args.size()) game_key = args[++i];
    else if (a == "-h" || a == "--help" || a == "help") {
      usage();
      return 0;
    } else if (a.rfind("--", 0) == 0) {
      std::fprintf(stderr, "unknown option %s\n", a.c_str());
      return 1;
    } else {
      pos.push_back(a);
    }
  }
  const char *home = std::getenv("HOME");
  if (repo.empty()) repo = default_repo(home, argv[0]);

  const std::string cmd = pos.empty() ? "" : pos[0];
  if (cmd == "doctor") {
    cmd_doctor(json);
    return 0;
  }
  if (cmd == "port") {
    cmd_port(json);
    return 0;
  }
  if (cmd == "status") {
    cmd_status(repo, json);
    return 0;
  }
  if (cmd == "play") {
    const GameDef *g = nullptr;
    if (!game_key.empty()) {
      for (const auto &d : kGames)
        if (game_key == d.key) g = &d;
      if (!g) {
        std::fprintf(stderr, "unknown game '%s' (gears1, gears2, gears3, judgment)\n", game_key.c_str());
        return 1;
      }
    } else {
      g = &kGames[1];  // Gears 2, the title this project grew out of
    }
    if (!valid_lang(lang_choice)) {
      std::fprintf(stderr, "unknown language '%s' (auto, en, es, fr, de, it, pt-BR, pl, hu, ru, ja, zh-Hans, ko)\n",
                   lang_choice.c_str());
      return 1;
    }
    for (const auto& v : set_args)
      if (!valid_set_arg(v.rfind("--", 0) == 0 ? v : "--" + v)) {
        std::fprintf(stderr, "bad --set '%s' (expected --name=value)\n", v.c_str());
        return 1;
      }
    return cmd_play_native(repo, g->key, lang_choice, set_args, extra_file, dry_run, json);
  }
  if (cmd == "probe" || cmd == "list" || cmd == "install") {
    if (pos.size() < 2) {
      std::fprintf(stderr, "%s needs a path\n", cmd.c_str());
      return 1;
    }
    fs::path p = pos[1];
    std::error_code ec;
    if (!fs::exists(p, ec)) {
      std::fprintf(stderr, "No such file or folder: %s\n", p.string().c_str());
      return 1;
    }
    if (cmd == "probe") cmd_probe(p, json);
    else if (cmd == "list") cmd_list(p, json);
    else return cmd_install(p, repo, json, force);
    return 0;
  }
  std::fprintf(stderr, "unknown command '%s'\n\n", cmd.c_str());
  usage();
  return 1;
}
