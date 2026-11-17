// COGBox for macOS - the launcher window.
//
// The app is a thin, native front end over the `cogbox-mac` command line tool that ships inside the bundle: the
// tool does the work (identify a copy, verify it, unpack it), the app shows what it found and what is still
// missing. Keeping the logic in the tool means the same code can be scripted, tested, and reused by the ports.
import AppKit
import CoreGraphics
import SwiftUI

// MARK: - the tool's JSON

struct GameStatus: Decodable, Identifiable {
    let key: String
    let name: String
    let copy: Bool
    let update: Bool
    let port: Bool
    let state: String
    let portPath: String?
    var id: String { key }
}

struct LibStatus: Decodable {
    let repo: String
    let games: [GameStatus]
}

struct HostInfo: Decodable {
    let os: String
    let machine: String
    let cpu: String
    let cores: Int
    let memBytes: UInt64
    let rosetta: Bool
    let metal: Bool
    let gpu: String
    let gpuUnified: Bool
    let vulkanLoaders: [String]
}

struct ProbeResult: Decodable {
    struct Game: Decodable {
        let key: String
        let name: String
    }
    struct Xex: Decodable {
        let version: String
        let size: UInt64
        let matchesPort: Bool
    }
    struct Package: Decodable {
        let titleUpdate: Bool
        let version: String
    }
    let kind: String
    let kindLabel: String
    let ok: Bool
    let game: Game?
    let xex: Xex?
    let package: Package?
    let files: UInt64
    let bytes: UInt64
    let error: String?
}

/// `play --native --dry-run --json`: is a game built and ready to start on this Mac?
struct PlayInfo: Decodable {
    let ok: Bool
    let game: String?
    let exe: String?
    let cwd: String?
    let data: Bool?
    let update: Bool?
    let needsUpdate: Bool?
    let error: String?
}

// MARK: - running the tool

enum Tool {
    static var url: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cogbox-mac")
    }

    struct Output {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    /// Run the tool and wait. `onProgress` is called for every progress line on stderr.
    static func run(_ args: [String], onProgress: ((Double, String) -> Void)? = nil) -> Output {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        var errText = ""
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            lock.lock(); errText += s; lock.unlock()
            if let onProgress {
                for line in s.split(separator: "\n") where line.hasPrefix("{") {
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       obj["event"] as? String == "progress" {
                        let pct = (obj["pct"] as? Double ?? 0) / 100.0
                        onProgress(pct, obj["file"] as? String ?? "")
                    }
                }
            }
        }
        do {
            try p.run()
        } catch {
            return Output(code: -1, stdout: "",
                          stderr: "could not start cogbox-mac: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); let e = errText; lock.unlock()
        return Output(code: p.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: e)
    }

    static func json<T: Decodable>(_ type: T.Type, _ args: [String]) -> T? {
        let r = run(args)
        guard let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Start a game without collecting its output. A game writes its own log file; an unread Pipe would fill up
    /// and stall it, so both streams go to /dev/null. The CLI stays alive until the game exits, and the caller
    /// observes that through `terminationHandler`.
    static func start(_ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }
}

// MARK: - languages
// COGBox for Windows ships lang/<code>.txt (12 languages) and translates both its launcher and the ports'
// in-game text. On macOS the CLI passes --cogbox_ui_lang for the latter; this front end offers the same list.
// The window itself is bilingual (English / Simplified Chinese): the other languages have no launcher copy here,
// but their in-game COGBox text still comes from the shared translation files.
private enum Lang {
    static let options: [(code: String, name: String)] = [
        ("auto", "跟随系统 / Follow system"),
        ("en", "English"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("it", "Italiano"), ("pt-BR", "Português (Brasil)"), ("pl", "Polski"), ("hu", "Magyar"),
        ("ru", "Русский"), ("ja", "日本語"), ("zh-Hans", "简体中文"), ("ko", "한국어")
    ]

    /// "auto" maps the Mac's first preferred language onto a COGBox code, the same way the CLI does.
    static func resolve(_ stored: String) -> String {
        if stored != "auto" { return stored }
        let l = (Locale.preferredLanguages.first ?? "en").lowercased().replacingOccurrences(of: "_", with: "-")
        if l.hasPrefix("zh-hans") || l.hasPrefix("zh-cn") || l.hasPrefix("zh-chs") || l == "zh" { return "zh-Hans" }
        if l.hasPrefix("pt-br") || l == "pt" { return "pt-BR" }
        for c in ["es", "fr", "de", "it", "pl", "hu", "ru", "ja", "ko"] {
            if l == c || l.hasPrefix(c + "-") { return c }
        }
        return "en"
    }

    static func name(_ code: String) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}

// MARK: - game settings
// Windows' launcher (gears_settings.cpp) turns ~60 boxes into command-line switches. Only the switches the macOS
// ports really register are offered here; each row's first choice is "keep the launcher's default" and sends
// nothing at all, so an untouched settings page is byte-for-byte the old run_*.sh launch.
struct CogSetting: Identifiable {
    let key: String
    var id: String { key }
    let tab: String
    let en: String, zh: String
    let choices: [String], zhChoices: [String]
    let args: [[String]]
    let perGame: [String: [[String]]]?
    let onlyGames: [String]?
    func argsFor(_ index: Int, _ game: String) -> [String] {
        let table = perGame?[game] ?? args
        return index >= 0 && index < table.count ? table[index] : []
    }
}

/// The main display's refresh rate, for "match my monitor" frame caps. 0 when CoreGraphics cannot tell
/// (some virtual / mirrored displays report 0), in which case the row falls back to 60 Hz.
private enum HostCapabilities {
    static var mainRefreshRate: Int {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return 0 }
        let hz = mode.refreshRate
        return hz > 1.0 ? Int(hz.rounded()) : 0
    }
    static func frameCapArgs(_ game: String) -> [String] {
        let hz = mainRefreshRate > 0 ? mainRefreshRate : 60
        let key = game == "gears2" ? "gow2_max_fps" : game == "gears3" ? "gow3_max_fps" : "gowj_max_fps"
        return ["--\(key)=\(hz)"]
    }
    /// The CLI's `host` command already gathers this; shown on the Advanced tab so the user can compare
    /// the machine's capability with the switches Windows' launcher would disable automatically.
    static func summary(_ h: HostInfo?) -> String {
        guard let h else { return "—" }
        let gb = Double(h.memBytes) / 1_073_741_824.0
        let mem = String(format: "%.0f GB", gb)
        let gpu = h.gpu.isEmpty ? (h.metal ? "Metal" : "no Metal") : h.gpu
        return "\(h.cpu) · \(h.cores) cores · \(mem)\n\(gpu)\(h.gpuUnified ? " (unified memory)" : "")\n" +
               "\(h.os) · main display \(mainRefreshRate > 0 ? "\(mainRefreshRate) Hz" : "refresh rate unknown")"
    }
}

/// The full per-key binding table. Defaults mirror the SDK cvars (Gears 3 / Judgment) or the
/// COGBox Gears layout that port/run_gow2.sh passes (Gears 2). An empty field sends no switch at
/// all, so the game keeps its own default.
private enum Keybinds {
    struct Row {
        let cvar: String, button: String, action: String, zh: String, sdk: String, g2: String?
    }
    static let rows: [Row] = [
        Row(cvar: "keybind_right_trigger",   button: "RT",  action: "Fire",                  zh: "开火",       sdk: "E,O",          g2: "LMB"),
        Row(cvar: "keybind_left_trigger",    button: "LT",  action: "Aim",                   zh: "瞄准",       sdk: "Q,I",          g2: "RMB"),
        Row(cvar: "keybind_a",               button: "A",   action: "Cover / roadie run",    zh: "掩体 / 冲刺", sdk: "Semicolon,Space", g2: "Space"),
        Row(cvar: "keybind_b",               button: "B",   action: "Melee / chainsaw",      zh: "近战 / 链锯", sdk: "Quote,Backspace", g2: "F"),
        Row(cvar: "keybind_x",               button: "X",   action: "Use / pick up",         zh: "使用 / 拾取", sdk: "L",            g2: "E"),
        Row(cvar: "keybind_y",               button: "Y",   action: "Point of interest",     zh: "关注点",      sdk: "P",            g2: "Q"),
        Row(cvar: "keybind_right_shoulder",  button: "RB",  action: "Reload",                zh: "装弹",        sdk: "3",            g2: "R"),
        Row(cvar: "keybind_left_shoulder",   button: "LB",  action: "Tactical display",      zh: "战术面板",    sdk: "1",            g2: "Tab"),
        Row(cvar: "keybind_dpad_left",       button: "D←",  action: "Weapon (left)",         zh: "武器（左）",  sdk: "Shift+Left",   g2: "1"),
        Row(cvar: "keybind_dpad_right",      button: "D→",  action: "Weapon (right)",        zh: "武器（右）",  sdk: "Shift+Right",  g2: "2"),
        Row(cvar: "keybind_dpad_up",         button: "D↑",  action: "Weapon (up)",           zh: "武器（上）",  sdk: "Shift+Up",     g2: "3"),
        Row(cvar: "keybind_dpad_down",       button: "D↓",  action: "Grenades",              zh: "手雷",        sdk: "Shift+Down",   g2: "4"),
        Row(cvar: "keybind_rstick_press",    button: "R3",  action: "Zoom",                  zh: "缩放",        sdk: "K",            g2: "MMB,Z"),
        Row(cvar: "keybind_lstick_press",    button: "L3",  action: "Left stick click",      zh: "左摇杆按下",  sdk: "F",            g2: "C"),
        Row(cvar: "keybind_start",           button: "Start", action: "Pause menu",          zh: "暂停菜单",    sdk: "X,Return",     g2: "Escape,Return"),
        Row(cvar: "keybind_back",            button: "Back", action: "Back / scores",        zh: "返回 / 计分板", sdk: "Z,Tab",      g2: "Backspace"),
        Row(cvar: "keybind_lstick_up",       button: "L↑",  action: "Move forward",          zh: "前进",        sdk: "W",            g2: nil),
        Row(cvar: "keybind_lstick_down",     button: "L↓",  action: "Move back",             zh: "后退",        sdk: "S",            g2: nil),
        Row(cvar: "keybind_lstick_left",     button: "L←",  action: "Strafe left",           zh: "左移",        sdk: "A",            g2: nil),
        Row(cvar: "keybind_lstick_right",    button: "L→",  action: "Strafe right",          zh: "右移",        sdk: "D",            g2: nil),
        Row(cvar: "keybind_rstick_up",       button: "R↑",  action: "Look up",               zh: "视角上",      sdk: "Up",           g2: nil),
        Row(cvar: "keybind_rstick_down",     button: "R↓",  action: "Look down",             zh: "视角下",      sdk: "Down",         g2: nil),
        Row(cvar: "keybind_rstick_left",     button: "R←",  action: "Look left",             zh: "视角左",      sdk: "Left",         g2: nil),
        Row(cvar: "keybind_rstick_right",    button: "R→",  action: "Look right",            zh: "视角右",      sdk: "Right",        g2: nil),
        Row(cvar: "keybind_guide",           button: "Guide", action: "Guide button",        zh: "Guide 键",    sdk: "",             g2: nil),
        Row(cvar: "keybind_walk",            button: "Walk", action: "Walk (hold / toggle)", zh: "步行（按住/切换）", sdk: "",       g2: nil),
    ]
    /// rex::ui::ParseVirtualKey's table (sdk-patched-cg/src/ui/keybinds.cpp).
    static let keyNames: Set<String> = Set("""
        F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 F13 F14 F15 F16 F17 F18 F19 F20 F21 F22 F23 F24
        A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0 1 2 3 4 5 6 7 8 9
        Backtick Minus Plus Comma Period Semicolon Slash Backslash LBracket RBracket Quote
        Escape Return Space Tab Backspace Delete Insert Home End PageUp PageDown Left Right Up Down
        Shift Control Alt CapsLock NumLock ScrollLock PrintScreen Pause
        Numpad0 Numpad1 Numpad2 Numpad3 Numpad4 Numpad5 Numpad6 Numpad7 Numpad8 Numpad9
        NumpadEnter NumpadPlus NumpadMinus NumpadStar NumpadSlash LMB RMB MMB
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    static let modifiers: Set<String> = ["Shift", "Ctrl", "Control", "Alt"]
    static func `default`(_ r: Row, game: String) -> String {
        game == "gears2" ? (r.g2 ?? r.sdk) : r.sdk
    }
    /// Tokens the runtime would silently ignore. Empty = everything is a real key name.
    static func invalidTokens(_ value: String) -> [String] {
        value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.filter { token in
                let parts = token.split(separator: "+").map(String.init)
                if parts.contains(where: { !modifiers.contains($0) && !keyNames.contains($0) }) { return true }
                if parts.dropLast().contains(where: { !modifiers.contains($0) }) { return true }
                return parts.isEmpty || !keyNames.contains(parts.last!)
            }
    }
}

private enum CogSettings {
    static let tabs = ["Display", "Graphics", "Controls", "Gameplay", "Achievements", "Advanced"]

    static func tabName(_ t: String, zh: Bool) -> String {
        let names = ["Display": "显示", "Graphics": "画面", "Controls": "控制", "Gameplay": "游戏",
                     "Achievements": "成就", "Advanced": "高级"]
        return zh ? (names[t] ?? t) : t
    }

    private static func s(_ key: String, _ tab: String, _ en: String, _ zh: String,
                          _ choices: [String], _ zhChoices: [String], _ args: [[String]],
                          _ perGame: [String: [[String]]]? = nil, only: [String]? = nil) -> CogSetting {
        CogSetting(key: key, tab: tab, en: en, zh: zh, choices: choices, zhChoices: zhChoices,
                   args: args, perGame: perGame, onlyGames: only)
    }

    static let all: [CogSetting] = [
        // ---- Display ----
        s("fullscreen", "Display", "Display mode", "显示模式",
          ["Game default", "Windowed", "Borderless fullscreen", "Exclusive fullscreen"],
          ["跟随游戏默认", "窗口化", "无边框全屏", "独占全屏"],
          [[], ["--fullscreen=false"], ["--fullscreen=true"],
           ["--fullscreen=true", "--fullscreen_exclusive=true"]]),
        s("window", "Display", "Window size", "窗口尺寸",
          ["Game default", "1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"],
          ["跟随游戏默认", "1280 x 720", "1600 x 900", "1920 x 1080", "2560 x 1440"],
          [[], ["--window_width=1280", "--window_height=720"],
           ["--window_width=1600", "--window_height=900"],
           ["--window_width=1920", "--window_height=1080"],
           ["--window_width=2560", "--window_height=1440"]]),
        s("resolution", "Display", "Render resolution", "渲染分辨率",
          ["Original (720p)", "2x - 1440p", "3x - 4K", "4x - 5K (heavy)", "1080p upscale"],
          ["原始 720p", "2 倍 1440p", "3 倍 4K", "4 倍 5K（很重）", "1080p 升采样"],
          [[], ["--gow2_renderer_resolution_scale=2"], ["--gow2_renderer_resolution_scale=3"],
           ["--gow2_renderer_resolution_scale=4"],
           ["--gow2_renderer_resolution_scale=1", "--gow2_present_native_size=true",
            "--gow2_present_upscale_filter=lanczos", "--gow2_present_sharpen=0.5"]]),
        // The macOS path presents through Vulkan, so this is gow2_gpu_vsync (the D3D12 switch did nothing
        // here, and it also forbade immediate/mailbox, which left FIFO only - with a frame cap on top that
        // measured 30 FPS where 66 was available).
        s("vsync", "Display", "V-Sync", "垂直同步",
          ["Off (default)", "On"], ["关（默认）", "开"],
          [[], ["--gow2_gpu_vsync=true"]]),
        s("framecap", "Display", "Frame rate limit", "帧率上限",
          ["Game default (30)", "40", "45", "60", "90", "120", "144", "180", "Unlimited"],
          ["跟随游戏默认（30）", "40", "45", "60", "90", "120", "144", "180", "不限制"],
          { let caps = [40, 45, 60, 90, 120, 144, 180, -1]
            var t: [[String]] = [[]]
            for c in caps {
                t.append(["--gow2_max_fps=\(c)"])
            }
            return t }(),
          { let caps = [40, 45, 60, 90, 120, 144, 180, -1]
            var g2: [[String]] = [[]], g3: [[String]] = [[]], gj: [[String]] = [[]]
            for c in caps {
                g2.append(["--gow2_max_fps=\(c)"])
                g3.append(["--gow3_max_fps=\(c)"])
                gj.append(["--gowj_max_fps=\(c)"])
            }
            return ["gears2": g2, "gears3": g3, "judgment": gj] }()),
        s("matchrefresh", "Display", "Match the display refresh rate", "匹配显示器刷新率",
          ["Game default", "Match monitor (sets the frame cap)"],
          ["跟随游戏默认", "匹配显示器（设置帧率上限）"],
          [[], HostCapabilities.frameCapArgs("gears2")],
          { var t: [String: [[String]]] = [:]
            for g in ["gears2", "gears3", "judgment"] { t[g] = [[], HostCapabilities.frameCapArgs(g)] }
            return t }()),
        s("fpsbar", "Display", "FPS counter", "帧率计数器",
          ["Off", "Bar at the top", "Bar at the bottom"], ["关", "顶部横条", "底部横条"],
          [[], ["--gow2_fps_bar=top"], ["--gow2_fps_bar=bottom"]]),
        s("hidenotes", "Display", "Hide on-screen notes", "隐藏屏幕提示",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--gow2_hide_onscreen_notes=true"]]),
        s("monitor", "Display", "Monitor", "显示器",
          ["Main screen", "Screen 1", "Screen 2", "Screen 3"],
          ["主屏", "屏幕 1", "屏幕 2", "屏幕 3"],
          [[], ["--monitor=1"], ["--monitor=2"], ["--monitor=3"]]),
        s("hdr", "Display", "HDR (experimental)", "HDR（实验性）",
          ["Off (default)", "On"], ["关（默认）", "开"],
          [[], ["--present_hdr=true", "--gow2_hdr_paper_white=203", "--gow2_hdr_peak=1000"]]),
        s("hdrpaper", "Display", "HDR paper white (nits)", "HDR 纸白亮度（尼特）",
          ["Default (203)", "120", "160", "250", "300", "400"],
          ["默认（203）", "120", "160", "250", "300", "400"],
          [[], ["--gow2_hdr_paper_white=120"], ["--gow2_hdr_paper_white=160"],
           ["--gow2_hdr_paper_white=250"], ["--gow2_hdr_paper_white=300"],
           ["--gow2_hdr_paper_white=400"]]),
        s("hdrpeak", "Display", "HDR peak (nits)", "HDR 峰值亮度（尼特）",
          ["Default (1000)", "400", "600", "1500", "2000", "4000"],
          ["默认（1000）", "400", "600", "1500", "2000", "4000"],
          [[], ["--gow2_hdr_peak=400"], ["--gow2_hdr_peak=600"],
           ["--gow2_hdr_peak=1500"], ["--gow2_hdr_peak=2000"], ["--gow2_hdr_peak=4000"]]),
        s("gamma", "Display", "Gamma (extra display ramp)", "伽马（额外显示曲线）",
          ["Game default (1.0)", "0.8 (brighter)", "0.9", "1.1", "1.2 (darker shadows)", "1.3"],
          ["跟随游戏默认（1.0）", "0.8（更亮）", "0.9", "1.1", "1.2（暗部更暗）", "1.3"],
          { let v = [0.8, 0.9, 1.1, 1.2, 1.3]
            return [[]] + v.map { ["--gow2_present_gamma=\($0)"] } }()),
        s("sharpen", "Display", "Upscale sharpening (1080p mode)", "升采样锐化（1080p 模式）",
          ["Default (on)", "Off"], ["默认（开）", "关"],
          [[], ["--gow2_present_sharpen=0"]]),
        s("ultrawide", "Display", "Ultrawide", "超宽屏",
          ["Off", "On"], ["关", "开"],
          [[], ["--gow2_ultrawide=true"]],
          ["gears2": [[], ["--gow2_ultrawide=true"]],
           "gears3": [[], ["--gow3_ultrawide=true"]],
           "judgment": [[], ["--gowj_ultrawide=true"]]]),

        // ---- Graphics ----
        s("aa", "Graphics", "Anti-aliasing", "抗锯齿",
          ["Game default", "SMAA"], ["跟随游戏默认", "SMAA"],
          [[], ["--gow2_present_aa=smaa"]]),
        s("ao", "Graphics", "Ambient occlusion", "环境光遮蔽",
          ["Game default", "High (XeGTAO)", "Ultra (XeGTAO)", "CACAO"],
          ["跟随游戏默认", "高（XeGTAO）", "极高（XeGTAO）", "CACAO"],
          [[], ["--gow2_ao=gtao", "--gow2_ao_quality=high", "--gow2_ao_denoise=2"],
           ["--gow2_ao=gtao", "--gow2_ao_quality=ultra"],
           ["--gow2_ao_algo=cacao", "--gow2_ao_quality=low", "--gow2_ao_cacao_blur=3"]]),
        s("aniso", "Graphics", "16x anisotropic filtering", "16 倍各向异性过滤",
          ["Off", "On"], ["关", "开"],
          [[], ["--gow2_patch_aniso16=true"]],
          ["gears2": [[], ["--gow2_patch_aniso16=true"]],
           "gears3": [[], ["--gow3_patch_aniso16=true"]],
           "judgment": [[], ["--gowj_aniso16=true"]]]),
        s("pool", "Graphics", "Texture memory", "纹理显存",
          ["Game default", "256 MB", "320 MB"], ["跟随游戏默认", "256 MB", "320 MB"],
          [[], ["--gow2_patch_texture_pool_mb=256"], ["--gow2_patch_texture_pool_mb=320"]],
          ["gears2": [[], ["--gow2_patch_texture_pool_mb=256"], ["--gow2_patch_texture_pool_mb=320"]],
           "gears3": [[], ["--gow3_texture_pool_mb=256"], ["--gow3_texture_pool_mb=320"]],
           "judgment": [[], ["--gowj_texture_pool_mb=256"], ["--gowj_texture_pool_mb=320"]]]),
        s("lowlag", "Graphics", "Lower input lag", "降低输入延迟",
          ["Default", "One frame in flight"], ["默认", "单帧在途"],
          [[], ["--gow2_renderer_frames_in_flight=1"]]),

        // GitHub #105: Gears 3's half-resolution (pitch 640) depth-of-field chain follows the render scale.
        s("dofscale", "Graphics", "Depth of field at the render resolution", "景深按渲染分辨率计算",
          ["Game default", "On (needs render resolution above 720p)"],
          ["跟随游戏默认", "开（需渲染分辨率高于 720p）"],
          [[], ["--gow2_renderer_resolution_scale_pitches=640"]], only: ["gears3"]),

        s("preset", "Graphics", "Quality preset", "画质预设",
          ["Custom / unchanged", "Original (as on the console)", "High", "Ultra"],
          ["自定义 / 不改动", "原始（同主机）", "高", "极高"],
          [[], [], [], []]),
        s("trilinear", "Graphics", "Smooth texture detail steps (trilinear)", "平滑纹理细节过渡（三线性）",
          ["Game default", "On"], ["跟随游戏默认", "开"],
          [[], []],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|~=MipFilter=point>MipFilter=linear"]],
           "gears3": [[], ["--gow3_trilinear=true"]],
           "judgment": [[], ["--gowj_trilinear=true"]]]),
        s("mipfade", "Graphics", "Sharp textures show at once (fast mip fade)", "锐利纹理立即显示（快速 mip 渐变）",
          ["Game default", "On"], ["跟随游戏默认", "开"],
          [[], ["--gow3_fast_mip_fade=true"]],
          ["gears3": [[], ["--gow3_fast_mip_fade=true"]],
           "judgment": [[], ["--gowj_fast_mip_fade=true"]]],
          only: ["gears3", "judgment"]),
        s("drawdist", "Graphics", "Draw distance", "绘制距离",
          ["Game default", "1.5x", "2x"], ["跟随游戏默认", "1.5 倍", "2 倍"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=1.5"],
           ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=2"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=1.5"],
                      ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=2"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=1.5"],
                      ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=2"]],
           "judgment": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=1.5"],
                        ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MaxDrawDistanceScale=2"]]]),
        s("meshlod", "Graphics", "Character detail (LOD)", "角色细节（LOD）",
          ["Game default", "Higher", "Highest"], ["跟随游戏默认", "更高", "最高"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-1"],
           ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-3"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-1"],
                      ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-3"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-1"],
                      ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-3"]],
           "judgment": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-1"],
                        ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|SkeletalMeshLODBias=-3"]]]),
        s("motionblur", "Graphics", "Motion blur", "运动模糊",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MotionBlur=False"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|MotionBlur=False"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MotionBlur=False"]],
           "judgment": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|MotionBlur=False"]]]),
        s("dof", "Graphics", "Depth of field", "景深",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|DepthOfField=False"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|DepthOfField=False"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|DepthOfField=False"]],
           "judgment": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|DepthOfField=False"]]]),
        s("bloom", "Graphics", "Bloom", "泛光",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|Bloom=False"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|SystemSettings|Bloom=False"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|Bloom=False"]],
           "judgment": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|SystemSettings|Bloom=False"]]]),
        s("filmgrain", "Graphics", "Film grain", "胶片颗粒",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--gowj_no_film_grain=true"]]),
        s("shake", "Graphics", "Camera shake (roadie run)", "镜头晃动（奔跑）",
          ["Game default", "Less", "Off"], ["跟随游戏默认", "减弱", "关"],
          [[], ["--ue3_ini_edits=GearCamera.ini|GearGame.GearCamMod_CameraBone|RoadieRunShakyCamDampeningFactor*=0.5"],
           ["--ue3_ini_edits=GearCamera.ini|GearGame.GearCamMod_CameraBone|RoadieRunShakyCamDampeningFactor=0"]],
          ["gears2": [[], ["--ue3_ini_edits=GearCamera.ini|GearGame.GearCamMod_CameraBone|RoadieRunShakyCamDampeningFactor*=0.5"],
                      ["--ue3_ini_edits=GearCamera.ini|GearGame.GearCamMod_CameraBone|RoadieRunShakyCamDampeningFactor=0"]],
           "gears3": [[], ["--ue3_ini_edits=GearPawn.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor*=0.5;GearPawnMP.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor*=0.5"],
                      ["--ue3_ini_edits=GearPawn.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor=0;GearPawnMP.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor=0"]],
           "judgment": [[], ["--ue3_ini_edits=GearPawn.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor*=0.5;GearPawnMP.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor*=0.5;GearPawnFFA.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor*=0.5"],
                        ["--ue3_ini_edits=GearPawn.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor=0;GearPawnMP.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor=0;GearPawnFFA.ini|GearGame.GearPawn|RoadieRunShakyCamDampeningFactor=0"]]]),
        s("fov", "Graphics", "Field of view (%)", "视野（%）",
          ["100 (default)", "90", "110"], ["100（默认）", "90", "110"],
          [[], ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=0.9;GearPawn.ini|*|DefaultFOV*=0.9"],
           ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=1.1;GearPawn.ini|*|DefaultFOV*=1.1"]],
          ["gears2": [[], ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=0.9;GearPawn.ini|*|DefaultFOV*=0.9"],
                      ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=1.1;GearPawn.ini|*|DefaultFOV*=1.1"]],
           "gears3": [[], ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=0.9"],
                      ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=1.1"]],
           "judgment": [[], ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=0.9"],
                        ["--ue3_ini_edits=GearCamera.ini|*|FOVAngle*=1.1"]]]),

        // ---- Controls ----
        s("mnk", "Controls", "Keyboard and mouse", "键盘鼠标",
          ["Enabled (default)", "Disabled"], ["启用（默认）", "关闭"],
          [[], ["--mnk_mode=false", "--mnk_mouse=false"]]),
        // Gears 2 has its own mouse look (ue3_mouse_look.h): mouse counts turn the view directly instead of
        // deflecting the right stick, which the game caps - that cap is why a high stick sensitivity still felt slow.
        s("mouselook", "Controls", "Mouse look", "鼠标视角",
          ["Stick emulation (default)", "Native (recommended)"],
          ["摇杆模拟（默认）", "原生（推荐，跟手）"],
          [[], ["--ue3_mouse_look=true"]], only: ["gears2"]),
        // Both knobs, so the slider works whichever look mode is chosen: mnk_sensitivity for the stick path,
        // ue3_mouse_scale for the native one.
        s("sens", "Controls", "Mouse sensitivity", "鼠标灵敏度",
          ["1.0 (default)", "0.5", "1.5", "2.0", "3.0", "5.0"],
          ["1.0（默认）", "0.5", "1.5", "2.0", "3.0", "5.0"],
          [[], ["--mnk_sensitivity=0.5", "--ue3_mouse_scale=0.5"],
           ["--mnk_sensitivity=1.5", "--ue3_mouse_scale=1.5"],
           ["--mnk_sensitivity=2.0", "--ue3_mouse_scale=2.0"],
           ["--mnk_sensitivity=3.0", "--ue3_mouse_scale=3.0"],
           ["--mnk_sensitivity=5.0", "--ue3_mouse_scale=5.0"]]),
        s("vibration", "Controls", "Controller vibration", "手柄震动",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--vibration=false"]]),
        s("deadzone", "Controls", "Extra stick dead zone", "额外摇杆死区",
          ["Default", "5%", "10%", "15%", "20%", "25%"],
          ["默认", "5%", "10%", "15%", "20%", "25%"],
          { let v = [0.05, 0.10, 0.15, 0.20, 0.25]
            return [[]] + v.map { ["--left_stick_deadzone_percentage=\($0)",
                                   "--right_stick_deadzone_percentage=\($0)"] } }()),

        s("aimturn", "Controls", "Mouse turn when aiming", "瞄准时的鼠标转向",
          ["Game's (slower, default)", "Same as moving"], ["游戏默认（较慢）", "与移动一致"],
          [[], ["--ue3_mouse_fov_constant=false"]], only: ["gears2", "gears3"]),
        s("padprompts", "Controls", "Keep controller button prompts", "保留手柄按键提示",
          ["No (default: keyboard caps)", "Yes"], ["否（默认：键盘按键）", "是"],
          [[], ["--gow_button_prompts_keep_pad=true"]]),
        // The walk key itself is in the keybinds table below (Controls tab).
        s("walkmode", "Controls", "Walk key behaviour", "步行键行为",
          ["Hold (default)", "Press to toggle"], ["按住（默认）", "按一下切换"],
          [[], ["--mnk_walk_toggle=true"]]),
        s("radialdz", "Controls", "Radial stick dead zone", "径向摇杆死区",
          ["Game default", "8%", "12%", "16%", "20%", "25%"],
          ["跟随游戏默认", "8%", "12%", "16%", "20%", "25%"],
          { let v = [0.08, 0.12, 0.16, 0.20, 0.25]
            return [[]] + v.map { ["--pad_radial_deadzone=\($0)"] } }()),
        s("padlayout", "Controls", "Controller layout", "手柄布局",
          ["Game default", "Southpaw (sticks swapped)", "A and B swapped", "Bumpers and triggers swapped"],
          ["跟随游戏默认", "左撇子（摇杆互换）", "A / B 互换", "肩键 / 扳机互换"],
          [[], ["--pad_remap=sticks=swap"], ["--pad_remap=a=b,b=a"],
           ["--pad_remap=lb=lt,lt=lb,rb=rt,rt=rb"]]),

        // ---- Gameplay ----
        // SDK patch 49b: System Link LAN play. Peer IPs are entered on the Advanced tab (--net_peer_ip).
        s("systemlink", "Gameplay", "System Link - LAN play (experimental)", "System Link 局域网联机（实验性）",
          ["Off (default)", "On"], ["关（默认）", "开"],
          [[], ["--net_system_link=true"]]),
        s("splitlayout", "Gameplay", "Two-player split", "双人分屏布局",
          ["Top and bottom (game's own)", "Side by side"], ["上下（游戏默认）", "左右并排"],
          [[], ["--gow2_split_vertical=true"]], only: ["gears2"]),
        s("hordebots", "Gameplay", "Horde bots", "持久战机器人",
          ["Off (default)", "Add two bots (Back on scoreboard)"],
          ["关（默认）", "加两个机器人（计分板按 Back）"],
          [[], ["--gow2_horde_bots=true"]], only: ["gears2"]),
        s("players", "Gameplay", "Local players", "本地玩家数",
          ["1 (default)", "2", "3", "4"], ["1（默认）", "2", "3", "4"],
          [[], ["--local_players=2"], ["--local_players=3"], ["--local_players=4"]]),
        s("voicelang", "Gameplay", "Voice language", "语音语言",
          ["Game default", "English", "French", "German", "Italian", "Spanish", "Latin Spanish",
           "Polish", "Russian", "Japanese"],
          ["跟随游戏默认", "英语", "法语", "德语", "意大利语", "西班牙语", "拉美西班牙语",
           "波兰语", "俄语", "日语"],
          [[], ["--ue3_voice_language=INT"], ["--ue3_voice_language=FRA"], ["--ue3_voice_language=DEU"],
           ["--ue3_voice_language=ITA"], ["--ue3_voice_language=ESN"], ["--ue3_voice_language=ESM"],
           ["--ue3_voice_language=POL"], ["--ue3_voice_language=RUS"], ["--ue3_voice_language=JPN"]]),
        s("gamelang", "Gameplay", "Game language (menu / text)", "游戏语言（菜单/文本）",
          ["Game default", "English", "Simplified Chinese", "Japanese", "German", "French",
           "Spanish", "Italian", "Korean", "Traditional Chinese", "Portuguese", "Polish", "Russian"],
          ["跟随游戏默认", "英语", "简体中文", "日语", "德语", "法语", "西班牙语", "意大利语",
           "韩语", "繁体中文", "葡萄牙语", "波兰语", "俄语"],
          { // Xbox language / country IDs from gears_settings.cpp (GitHub #4, job 666)
            let pairs = [(1, 103), (17, 20), (2, 53), (3, 24), (4, 34), (5, 31), (6, 50),
                         (7, 56), (8, 101), (9, 13), (11, 82), (12, 88)]
            return [[]] + pairs.map { ["--user_language=\($0.0)", "--user_country=\($0.1)"] } }()),

        s("skiplogos", "Gameplay", "Skip the intro logos", "跳过开场 logo",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--ue3_ini_edits=Xe-GearEngine.ini|FullScreenMovie|-StartupMovies=EpicLogo;Xe-GearEngine.ini|FullScreenMovie|-StartupMovies=MGSLogo"]],
          ["gears2": [[], ["--ue3_ini_edits=Xe-GearEngine.ini|FullScreenMovie|-StartupMovies=EpicLogo;Xe-GearEngine.ini|FullScreenMovie|-StartupMovies=MGSLogo"]],
           "gears3": [[], ["--ue3_ini_edits=Xbox360-GearEngine.ini|FullScreenMovie|-StartupMovies=Open_Logos"]],
           "judgment": [[], ["--gowj_skip_logos=true"]]]),
        s("insane", "Gameplay", "Unlock Insane from the start", "开局解锁疯狂难度",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--gow3_unlock_insane=true"]], only: ["gears3"]),
        s("cheats", "Gameplay", "Cheats (hotkeys F5-F11)", "作弊（F5-F11 热键）",
          ["Off (default)", "On"], ["关（默认）", "开"],
          [[], ["--gow3_cheats=true"]], only: ["gears3"]),
        s("mutators", "Gameplay", "Unlock all mutators", "解锁全部突变器",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--gow3_unlock_mutators=true"]], only: ["gears3"]),
        s("mute", "Gameplay", "Mute when not the active window", "非活动窗口时静音",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--gow2_mute_unfocused=true"]],
          ["gears2": [[], ["--gow2_mute_unfocused=true"]],
           "gears3": [[], ["--gow3_mute_unfocused=true"]],
           "judgment": [[], ["--gowj_mute_unfocused=true"]]]),

        // ---- Achievements ----
        s("achstyle", "Achievements", "Popup style", "弹窗样式",
          ["Default (Xbox 360)", "Xbox", "PlayStation"], ["默认（Xbox 360）", "Xbox", "PlayStation"],
          [[], ["--cogbox_ach_style=xbox"], ["--cogbox_ach_style=ps5"]]),
        s("achcolour", "Achievements", "Popup colour (Xbox style)", "弹窗颜色（Xbox 样式）",
          ["Default", "Red", "Green", "Blue", "Purple", "Orange", "Pink", "Teal", "Grey", "Gold"],
          ["默认", "红", "绿", "蓝", "紫", "橙", "粉", "青", "灰", "金"],
          { let c = ["red", "green", "blue", "purple", "orange", "pink", "teal", "grey", "gold"]
            return [[]] + c.map { ["--cogbox_ach_colour=\($0)"] } }()),
        s("achposition", "Achievements", "Popup position", "弹窗位置",
          ["Default", "Top left", "Top centre", "Top right", "Bottom left", "Bottom centre", "Bottom right"],
          ["默认", "左上", "顶部居中", "右上", "左下", "底部居中", "右下"],
          { let p = ["top_left", "top_centre", "top_right", "bottom_left", "bottom_centre", "bottom_right"]
            return [[]] + p.map { ["--cogbox_ach_position=\($0)"] } }()),
        s("achsound", "Achievements", "Popup sound", "弹窗声音",
          ["On (default)", "Off"], ["开（默认）", "关"],
          [[], ["--cogbox_ach_sound=false"]]),
        s("achhide", "Achievements", "Hide achievement popups", "隐藏成就弹窗",
          ["No (default)", "Yes"], ["否（默认）", "是"],
          [[], ["--cogbox_ach_hide=true"]]),
    ]

    /// The quality presets (Windows' apply_preset, Gears 2/3/Judgment values): index = preset choice.
    static let presetMembers: Set<String> = ["resolution", "aa", "aniso", "trilinear", "mipfade",
                                             "pool", "drawdist", "motionblur", "dof", "bloom",
                                             "filmgrain", "shake", "fov"]
    static let presets: [Int: [String: Int]] = [
        1: [:],                                                                   // Original: everything back to the port's default
        2: ["resolution": 1, "aa": 1, "aniso": 1, "trilinear": 1, "mipfade": 1,
            "pool": 1, "drawdist": 1],                                            // High
        3: ["resolution": 2, "aa": 1, "aniso": 1, "trilinear": 1, "mipfade": 1,
            "pool": 2, "drawdist": 2],                                            // Ultra
    ]
}

// MARK: - model

@MainActor
final class AppModel: ObservableObject {
    @Published var status: LibStatus?
    @Published var host: HostInfo?
    @Published var selected: String = "gears2"
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var progressFile = ""
    @Published var toast: String?
    @Published var probe: ProbeResult?
    @Published var playable: [String: PlayInfo] = [:]
    @Published var runningKey: String?
    @Published var building = false
    @Published var buildLog = ""
    @Published var showBuildLog = false
    @Published var lang: String {
        didSet { UserDefaults.standard.set(lang, forKey: "cogbox.ui.lang") }
    }
    /// Per-game settings: game key -> setting id -> chosen index (0 = launcher default, sends nothing).
    @Published var settings: [String: [String: Int]] {
        didSet { UserDefaults.standard.set(settings, forKey: "cogbox.settings") }
    }
    /// Raw extra switches, one per line (Windows' out/extra-args.txt), per game.
    @Published var extraText: [String: String] {
        didSet { UserDefaults.standard.set(extraText, forKey: "cogbox.extraArgs") }
    }
    /// Free-text settings per game: "mods" (folders, one per line, joined with ';'), "gamertag",
    /// "peerip". Kept in one dictionary so a new text switch needs no new storage plumbing.
    @Published var textValues: [String: [String: String]] {
        didSet { UserDefaults.standard.set(textValues, forKey: "cogbox.text") }
    }
    @Published var showSettings = false
    /// Which tab the settings window opens on (`--settings-tab Graphics`).
    @Published var settingsTab = "Display"

    private var gameProcess: Process?
    static let keys = ["gears1", "gears2", "gears3", "judgment"]

    init() {
        lang = UserDefaults.standard.string(forKey: "cogbox.ui.lang") ?? "auto"
        settings = UserDefaults.standard.dictionary(forKey: "cogbox.settings") as? [String: [String: Int]] ?? [:]
        extraText = UserDefaults.standard.dictionary(forKey: "cogbox.extraArgs") as? [String: String] ?? [:]
        textValues = UserDefaults.standard.dictionary(forKey: "cogbox.text") as? [String: [String: String]] ?? [:]
        // One-time migration from the older per-game mods-only dictionary.
        if textValues.isEmpty, let old = UserDefaults.standard.dictionary(forKey: "cogbox.mods") as? [String: String] {
            textValues = old.reduce(into: [:]) { $0[$1.key] = ["mods": $1.value] }
        }
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--settings-tab"), i + 1 < argv.count {
            settingsTab = argv[i + 1]
        } else if let a = argv.first(where: { $0.hasPrefix("--settings-tab=") }) {
            settingsTab = String(a.dropFirst("--settings-tab=".count))
        }
    }

    /// The value shown and sent: an explicit choice first, otherwise the quality preset's value for that row
    /// (so a preset loaded from elsewhere, e.g. defaults/another Mac, still lights up the rows it sets).
    func choice(_ id: String, for game: String) -> Int {
        if let v = settings[game]?[id], v != 0 { return v }
        let preset = settings[game]?["preset"] ?? 0
        if preset > 0, let p = CogSettings.presets[preset], let v = p[id] { return v }
        return 0
    }
    func setChoice(_ id: String, _ value: Int, for game: String) {
        var all = settings
        var g = settings[game] ?? [:]
        func put(_ k: String, _ v: Int) {
            if v == 0 { g.removeValue(forKey: k) } else { g[k] = v }
        }
        if id == "preset" {
            put("preset", value)
            if value > 0, let preset = CogSettings.presets[value] {
                for k in CogSettings.presetMembers { g.removeValue(forKey: k) }
                for (k, v) in preset where v != 0 { g[k] = v }
            }
        } else if CogSettings.presetMembers.contains(id) {
            g.removeValue(forKey: "preset")   // a hand change makes the preset Custom
            put(id, value)
        } else {
            put(id, value)
        }
        all[game] = g
        settings = all                 // reassign so @Published / didSet fires
        refresh()
    }
    func setExtra(_ text: String, for game: String) {
        var all = extraText
        all[game] = text
        extraText = all
    }
    func setText(_ id: String, _ text: String, for game: String) {
        var all = textValues
        var g = all[game] ?? [:]
        if text.isEmpty { g.removeValue(forKey: id) } else { g[id] = text }
        all[game] = g
        textValues = all
    }
    func resetSettings(for game: String) {
        var all = settings; all[game] = [:]; settings = all
        var ex = extraText; ex[game] = ""; extraText = ex
        var tx = textValues; tx[game] = [:]; textValues = tx
        refresh()
    }
    func extra(for game: String) -> String { extraText[game] ?? "" }
    func text(_ id: String, for game: String) -> String { textValues[game]?[id] ?? "" }
    private func lines(_ id: String, for game: String) -> [String] {
        text(id, for: game).split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    /// Free-text switches, each already formatted as one --set value. Empty = no switch at all.
    func textArgs(for game: String) -> [String] {
        var out: [String] = []
        let mods = lines("mods", for: game)
        if !mods.isEmpty { out.append("--ue3_mods=" + mods.joined(separator: ";")) }
        // SDK patch 54: 15 ASCII letters / digits / single spaces; the runtime filters the rest.
        let tag = lines("gamertag", for: game).first ?? ""
        if !tag.isEmpty { out.append("--user_gamertag=" + tag) }
        let peers = lines("peerip", for: game)
        if !peers.isEmpty { out.append("--net_peer_ip=" + peers.joined(separator: ",")) }
        // Per-key bindings: only rows the user actually filled in are sent. Sorted so args.txt
        // is stable and comparable between runs.
        let binds = (textValues[game] ?? [:])
            .filter { $0.key.hasPrefix("keybind_") }
            .map { (k, v) -> (String, String) in
                (k, v.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                     .filter { !$0.isEmpty }.joined(separator: ","))
            }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
        for (k, v) in binds { out.append("--\(k)=\(v)") }
        // Windows' launcher sends the 0.4 walk scale together with a chosen walk key.
        if binds.contains(where: { $0.0 == "keybind_walk" }) { out.append("--mnk_walk_scale=0.4") }
        return out
    }
    /// Every switch the user actually changed, as `--set` values for the CLI.
    /// The engine-config edits of several controls are joined into ONE --ue3_ini_edits (a later --set of the
    /// same name would replace the earlier one, so they must not be sent separately).
    func settingArgs(for game: String) -> [String] {
        var out: [String] = []
        var ini: [String] = []
        for s in CogSettings.all {
            if let only = s.onlyGames, !only.contains(game) { continue }
            let i = choice(s.key, for: game)
            guard i != 0 else { continue }
            for v in s.argsFor(i, game) {
                if v.hasPrefix("--ue3_ini_edits=") {
                    ini.append(String(v.dropFirst("--ue3_ini_edits=".count)))
                } else {
                    out.append(v)
                }
            }
        }
        if !ini.isEmpty { out.append("--ue3_ini_edits=" + ini.joined(separator: ";")) }
        return out
    }
    /// The extra-switches file the CLI reads (Windows' extra-args.txt); nil when there is nothing to write.
    func extraFile(for game: String) -> String? {
        let text = extraText[game] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("COGBox")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("\(game)-extra-args.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
    /// The shared tail of the dry-run / launch command: language, settings and extra switches.
    func launchArgs(_ game: String) -> [String] {
        var a = ["play", "--native", "--game", game, "--lang", resolvedLang]
        for v in settingArgs(for: game) { a += ["--set", v] }
        for v in textArgs(for: game) { a += ["--set", v] }
        if let f = extraFile(for: game) { a += ["--extra-args", f] }
        recordArgs(a, for: game)
        return a
    }

    /// Keep the switches of the last launch in Application Support (Windows writes the same list to args.txt),
    /// so the settings page, the Advanced box and what the game really got can be compared.
    private func recordArgs(_ args: [String], for game: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("COGBox")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let text = "# COGBox for macOS - the switches this launch used\n" + args.joined(separator: "\n") + "\n"
        try? text.write(to: base.appendingPathComponent("\(game)-args.txt"), atomically: true, encoding: .utf8)
    }

    /// The code actually handed to the game ("auto" resolved against this Mac).
    var resolvedLang: String { Lang.resolve(lang) }
    /// The launcher window is English, or Simplified Chinese when that is the chosen language.
    func t(_ en: String, _ zh: String) -> String { resolvedLang == "zh-Hans" ? zh : en }

    func setLang(_ code: String) {
        lang = code
        refresh()
    }

    /// The checkout this app was built from: walk up from the bundle looking for port/ + Gears2-Native/.
    /// Same rule as `cogbox-mac play --native`, so a clone anywhere works.
    var repo: URL? {
        let fm = FileManager.default
        var p = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<8 {
            p = p.deletingLastPathComponent()
            if fm.fileExists(atPath: p.appendingPathComponent("port/build_game.sh").path),
               fm.fileExists(atPath: p.appendingPathComponent("Gears2-Native").path) {
                return p
            }
        }
        return nil
    }

    func refresh() {
        host = Tool.json(HostInfo.self, ["doctor", "--json"])
        status = Tool.json(LibStatus.self, ["status", "--json"])
        // `play --dry-run` checks the real macOS build, its data and the KosmicKrisp ICD. Four short child
        // processes; this is what decides whether the Play button is offered.
        var found: [String: PlayInfo] = [:]
        for key in Self.keys {
            let args = launchArgs(key) + ["--dry-run", "--json"]
            if let info = Tool.json(PlayInfo.self, args), info.ok {
                found[key] = info
            }
        }
        playable = found
    }

    /// Start the native port through the CLI. The GUI never waits on it: the process is kept alive here and the
    /// toast reports the exit code when the game closes.
    func launch(_ key: String, name: String) {
        guard playable[key] != nil, runningKey == nil else { return }
        do {
            let p = try Tool.start(launchArgs(key))
            runningKey = key
            toast = t("\(name) is running…", "\(name) 正在运行…")
            p.terminationHandler = { [weak self] proc in
                let code = proc.terminationStatus
                Task { @MainActor in
                    guard let self else { return }
                    self.gameProcess = nil
                    self.runningKey = nil
                    self.toast = code == 0
                        ? self.t("\(name) quit", "\(name) 已退出")
                        : self.t("\(name) exited with code \(code) - see the game log",
                                 "\(name) 退出码 \(code)，详情见游戏日志")
                }
            }
            gameProcess = p
        } catch {
            toast = t("Could not start: \(error.localizedDescription)",
                      "启动失败：\(error.localizedDescription)")
        }
    }

    func game(_ key: String) -> GameStatus? {
        status?.games.first { $0.key == key }
    }

    /// Identify a dropped file and, if it looks like a copy, ask before unpacking.
    func inspect(_ url: URL) {
        busy = true
        toast = nil
        Task.detached(priority: .userInitiated) {
            let r = Tool.json(ProbeResult.self, ["probe", url.path, "--json"])
            await MainActor.run {
                self.probe = r
                self.busy = false
                if let r, r.ok, let g = r.game {
                    self.selected = g.key
                    self.toast = "\(g.name) - \(r.kindLabel), \(r.files) files"
                } else {
                    self.toast = r?.error ?? self.t("This file is not an Xbox 360 copy COGBox recognises.",
                                                    "这不是 COGBox 能识别的 Xbox 360 游戏副本。")
                }
            }
        }
    }

    func install(_ url: URL) {
        busy = true
        progress = 0
        toast = nil
        Task.detached(priority: .userInitiated) {
            // install unpacks into this checkout's <Game>-Native/game/ - the same place upstream's
            // builders put it. .gitignore is what keeps it out of git.
            let r = Tool.run(["install", url.path, "--force", "--json"]) { pct, file in
                Task { @MainActor in
                    self.progress = pct
                    self.progressFile = file
                }
            }
            await MainActor.run {
                self.busy = false
                self.progress = 1
                if r.code == 0 {
                    self.toast = self.t("Unpacked. Building the port for it now.",
                                        "解包完成，正在为它编译原生移植。")
                } else {
                    self.toast = r.stderr.isEmpty
                        ? self.t("Unpacking failed (exit \(r.code)).", "解包失败（退出码 \(r.code)）。")
                        : r.stderr
                }
                self.refresh()
                // Upstream ships prebuilt programs, so its players never compile anything. This fork cannot
                // ship binaries, so the build starts on its own as soon as the copy and its update are both
                // in place - the drag is the only thing a builder has to do.
                if r.code == 0, !self.building,
                   let g = self.status?.games.first(where: { $0.key == self.selected }),
                   g.copy, g.update || g.key == "gears3",
                   self.playable[g.key] == nil {
                    self.buildNative(g.key)
                }
            }
        }
    }

    /// Compile the native port from the copy that was just unpacked. Upstream ships prebuilt programs, so
    /// its players never see this step; we do not ship binaries, so the app runs the same script a builder
    /// would run by hand and shows its output.
    func buildNative(_ key: String) {
        guard let repo = repo else {
            toast = t("This app is not inside a source checkout, so there is nothing to build.",
                      "这个应用不在源码仓库里，没有可编译的东西。")
            return
        }
        building = true
        buildLog = ""
        showBuildLog = true
        let script = repo.appendingPathComponent("port/build_game.sh")
        Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, key]
            p.currentDirectoryURL = repo
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                Task { @MainActor in
                    self.buildLog += s
                    if self.buildLog.count > 300_000 {
                        self.buildLog = String(self.buildLog.suffix(200_000))
                    }
                }
            }
            do {
                try p.run()
            } catch {
                await MainActor.run {
                    self.buildLog += "could not start \(script.path): \(error.localizedDescription)\n"
                    self.building = false
                }
                return
            }
            p.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            await MainActor.run {
                self.building = false
                self.toast = p.terminationStatus == 0
                    ? self.t("Native port built. Press Play.", "原生移植编译完成，可以开始游戏了。")
                    : self.t("Build failed (exit \(p.terminationStatus)). See the log.",
                             "编译失败（退出码 \(p.terminationStatus)），详见日志。")
                self.refresh()
            }
        }
    }
}

// MARK: - palette

private enum P {
    static let bg = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let panel2 = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.93, green: 0.94, blue: 0.95)
    static let dim = Color(red: 0.60, green: 0.63, blue: 0.67)
    static let accent = Color(red: 0.85, green: 0.27, blue: 0.22)   // Gears red
    static let ok = Color(red: 0.36, green: 0.78, blue: 0.51)
    static let warn = Color(red: 0.95, green: 0.72, blue: 0.30)
}

// MARK: - views

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(P.line)
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(P.bg)
        .foregroundStyle(P.text)
        .onAppear {
            model.refresh()
            // `open COGBox.app --args --settings` jumps straight into the settings window (also handy for screenshots).
            if CommandLine.arguments.contains("--settings") { model.showSettings = true }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model, gameKey: model.selected, initialTab: model.settingsTab)
        }
        .sheet(isPresented: $model.showBuildLog) {
            BuildLogSheet(model: model)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(P.panel2, in: Capsule())
                    .overlay(Capsule().stroke(P.line))
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(P.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.inspect(url) }
            }
            return true
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("COGBOX").font(.system(size: 17, weight: .heavy)).tracking(3)
                Text("for macOS").font(.system(size: 11)).foregroundStyle(P.dim)
            }
            .padding(.horizontal, 18).padding(.top, 40).padding(.bottom, 16)  // clear of the traffic lights

            ForEach(model.status?.games ?? [], id: \.key) { g in
                Button {
                    model.selected = g.key
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(g.key == model.selected ? P.accent : P.panel2)
                            .frame(width: 26, height: 26)
                            .overlay(Text(String(g.name.prefix(1)))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(g.key == model.selected ? .white : P.dim))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).font(.system(size: 12.5, weight: .medium))
                            Text(stateLabel(g)).font(.system(size: 10.5)).foregroundStyle(color(g))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(g.key == model.selected ? Color.white.opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
            languageMenu
                .padding(.horizontal, 14).padding(.bottom, 10)
            hostStrip
        }
        .frame(width: 250)
        .background(P.panel)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(Lang.options, id: \.code) { opt in
                Button {
                    model.setLang(opt.code)
                } label: {
                    Text((model.lang == opt.code ? "✓  " : "    ") + opt.name)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe").font(.system(size: 11))
                Text(model.t("Language", "语言")).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(P.text)
                Text(Lang.name(model.resolvedLang))
                    .font(.system(size: 10)).foregroundStyle(P.text.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                    .foregroundStyle(P.text.opacity(0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(P.panel2, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .foregroundStyle(P.text)
        .tint(P.text)
    }

    private var hostStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.t("THIS MAC", "这台 MAC")).font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundStyle(P.dim)
            if let h = model.host {
                row("gpu", h.gpu)
                row("metal", h.metal ? model.t("available", "可用") : model.t("missing", "缺失"))
                row("vulkan", h.vulkanLoaders.isEmpty ? model.t("no loader", "无加载器")
                                                     : model.t("loadable", "可加载"))
                row("rosetta", h.rosetta ? model.t("installed", "已安装") : model.t("missing", "缺失"))
                row("macOS", "\(h.os) \(h.machine)")
            } else {
                Text(model.t("checking…", "检测中…")).font(.system(size: 11)).foregroundStyle(P.dim)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) { Rectangle().fill(P.line).frame(height: 1) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(P.dim)
            Text(v).font(.system(size: 10.5)).foregroundStyle(P.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private var detail: some View {
        let g = model.game(model.selected)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(g)
                steps(g)
                actions(g)
                portNote(g)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ g: GameStatus?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g?.name ?? model.t("Add your copy", "添加你的游戏副本"))
                .font(.system(size: 26, weight: .bold))
            Text(g.map(stateLabel) ?? model.t("Drop a disc image, a game folder or a title update here",
                                             "把光盘镜像、游戏目录或标题更新拖到这里"))
                .font(.system(size: 12.5))
                .foregroundStyle(g.map(color) ?? P.dim)
        }
    }

    private func steps(_ g: GameStatus?) -> some View {
        let info = g.flatMap { model.playable[$0.key] }
        let noUpdate = info?.needsUpdate == false
        return VStack(spacing: 0) {
            stepLine(1, model.t("Your own copy", "你自己的游戏副本"),
                     detail: info?.data == true ? model.t("in place", "已就位") : model.t("missing", "缺失"),
                     done: info?.data == true)
            Divider().overlay(P.line)
            stepLine(2, model.t("Title update", "标题更新"),
                     detail: noUpdate ? model.t("not required", "不需要")
                             : (info?.update == true ? model.t("in place", "已就位") : model.t("missing", "缺失")),
                     done: noUpdate || info?.update == true)
            Divider().overlay(P.line)
            stepLine(3, model.t("Native macOS port", "原生 macOS 移植"),
                     detail: info != nil ? model.t("built - ready to play", "已构建 · 可以运行")
                                        : model.t("not built yet", "尚未构建"),
                     done: info != nil)
        }
        .background(P.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(P.line))
    }

    private func stepLine(_ n: Int, _ title: String, detail: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? P.ok.opacity(0.18) : Color.white.opacity(0.05)).frame(width: 22, height: 22)
                if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(P.ok) }
                else { Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(P.dim) }
            }
            Text(title).font(.system(size: 12.5, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(done ? P.ok : P.dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func actions(_ g: GameStatus?) -> some View {
        let key = g?.key
        let info = key.flatMap { model.playable[$0] }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let key, let info {
                    Button {
                        model.launch(key, name: g?.name ?? key)
                    } label: {
                        Label(model.runningKey == key ? model.t("Running…", "运行中…")
                                                     : model.t("Play", "开始游戏"),
                              systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(P.ok, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.runningKey != nil || model.busy)

                    if let exe = info.exe {
                        Text(exe).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(P.dim).lineLimit(1).truncationMode(.middle)
                    }
                } else if g?.copy == true {
                    // The copy is in place but there is no program to start it: compile it here, from the
                    // data that was just unpacked. This is the one step upstream's release saves you.
                    Button {
                        model.buildNative(key ?? model.selected)
                    } label: {
                        Label(model.building ? model.t("Building…", "编译中…")
                                             : model.t("Build the port", "编译原生移植"),
                              systemImage: "hammer.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(P.accent, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.building || model.busy)
                }

                Button {
                    model.showSettings = true
                } label: {
                    Label(model.t("Settings", "设置"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(P.panel2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(P.text)
                }
                .buttonStyle(.plain)

                Button {
                    pickFile()
                } label: {
                    Label(model.t("Add your copy…", "添加副本…"), systemImage: "plus.circle.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(P.panel2, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(P.text)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }

            if model.busy {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: model.progress).tint(P.accent)
                    Text(model.progressFile.isEmpty ? model.t("working…", "处理中…") : model.progressFile)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(P.dim).lineLimit(1).truncationMode(.head)
                }
            }

            if let p = model.probe {
                Text("\(p.kindLabel) · \(p.files) files · \(byteText(p.bytes))"
                     + (p.xex.map { " · xex \($0.version)" } ?? "")
                     + (p.xex?.matchesPort == true ? model.t(" · the tested copy", " · 已验证的副本") : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(P.dim)
            }
        }
    }

    private func portNote(_ g: GameStatus?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.t("How Play works", "「开始游戏」是怎么工作的"), systemImage: "info.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(P.ok)
            Text(model.t("""
            Play starts the native macOS port built in this repository - no shell script and no Wine. COGBox \
            supplies the game data folder, the KosmicKrisp Vulkan driver, the patched rexglue SDK libraries and \
            the same launch arguments the old run_*.sh scripts used (including the Gears 2 EDRAM ownership \
            workaround). The game writes its own log file; the button stays disabled while it is running. \
            Gears 1 has no native build yet, so it has no Play button.
            """, """
            「开始游戏」直接启动仓库里编译好的原生 macOS 移植，不需要 shell 脚本，也不需要 Wine。COGBox \
            会准备好游戏数据目录、KosmicKrisp Vulkan 驱动、修补过的 rexglue SDK 库，以及旧 run_*.sh \
            脚本使用的那套启动参数（包含战争机器 2 的 EDRAM 归属绕过）。游戏自己写日志文件，运行期间按钮 \
            保持禁用。战争机器 1 还没有原生构建，所以没有「开始游戏」按钮。
            """)
            + "\n\n"
            + model.t("""
            Language: the 12 COGBox languages translate the in-game COGBox menu, Achievements and \
            popups; this window is English or Simplified Chinese. The games' own speech and subtitles are not \
            localised by this setting.
            """, """
            语言：12 种 COGBox 语言会翻译游戏内的 COGBox 菜单、成就和弹窗；\
            本窗口提供英文与简体中文。游戏本身的语音与字幕不受此设置影响。
            """))
            .font(.system(size: 11.5))
            .foregroundStyle(P.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(P.line))
    }

    // MARK: helpers

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = model.t("Choose your own copy: a disc image, an extracted game folder, or a title update.",
                                "选择你自己的游戏副本：光盘镜像、解包后的游戏目录，或标题更新。")
        if panel.runModal() == .OK, let url = panel.url { model.inspect(url) }
    }

    private func byteText(_ v: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(v))
    }

    private func stateLabel(_ g: GameStatus) -> String {
        if model.playable[g.key] != nil { return model.t("Ready to play", "可以运行") }
        if g.key == "gears1" { return model.t("No native build yet", "尚无原生构建") }
        return g.copy ? model.t("Copy unpacked, no native port yet", "副本已解包，尚无原生移植")
                      : model.t("No copy added", "尚未添加副本")
    }

    private func color(_ g: GameStatus) -> Color {
        if model.playable[g.key] != nil { return P.ok }
        return g.copy ? P.warn : P.dim
    }
}

// MARK: - settings window

struct BuildLogSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(model.t("Building the native port", "正在编译原生移植"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.building { ProgressView().controlSize(.small) }
                Button(model.t("Close", "关闭")) { model.showBuildLog = false }
                    .disabled(model.building)
            }
            ScrollViewReader { sp in
                ScrollView {
                    Text(model.buildLog.isEmpty ? model.t("Starting…", "启动中…") : model.buildLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("end")
                }
                .background(P.panel, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: model.buildLog) { _ in
                    sp.scrollTo("end", anchor: .bottom)
                }
            }
            Text(model.t("This compiles the renderer for the copy you just added; it can take a while. "
                         + "Leave it running - the Play button appears when it is done.",
                         "这一步为刚加进来的副本编译渲染器，耗时较长。放着不用管，编好后「开始游戏」会出现。"))
                .font(.system(size: 11))
                .foregroundStyle(P.dim)
        }
        .padding(18)
        .frame(width: 760, height: 520)
        .background(P.bg)
        .foregroundStyle(P.text)
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    let gameKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab: String

    init(model: AppModel, gameKey: String, initialTab: String) {
        self.model = model
        self.gameKey = gameKey
        _tab = State(initialValue: CogSettings.tabs.contains(initialTab) ? initialTab : "Display")
    }

    private var zh: Bool { model.resolvedLang == "zh-Hans" }
    private var gameName: String {
        model.status?.games.first { $0.key == gameKey }?.name ?? gameKey
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.t("Settings", "设置")).font(.system(size: 16, weight: .semibold))
                Text("· " + gameName).font(.system(size: 12)).foregroundStyle(P.dim)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(model.t("Done", "完成")).font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            Divider().overlay(P.line)

            Picker("", selection: $tab) {
                ForEach(CogSettings.tabs, id: \.self) { t in
                    Text(CogSettings.tabName(t, zh: zh)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider().overlay(P.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == "Advanced" {
                        advanced
                    } else {
                        ForEach(CogSettings.all.filter {
                            $0.tab == tab && ($0.onlyGames?.contains(gameKey) ?? true)
                        }) { item in
                            row(item)
                            Divider().overlay(P.line)
                        }
                        if tab == "Controls" { keybinds }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(P.line)
            HStack(spacing: 12) {
                Text(model.t("Only settings you change are passed to the game. The first choice always keeps the port's own default.",
                             "只有改动过的设置才会传给游戏；每行的第一项始终沿用移植本身的默认值。"))
                    .font(.system(size: 10)).foregroundStyle(P.dim)
                Spacer(minLength: 0)
                Button {
                    model.resetSettings(for: gameKey)
                } label: {
                    Text(model.t("Reset", "恢复默认")).font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 660, height: 620)
        .background(P.bg)
        .foregroundStyle(P.text)
        .colorScheme(.dark)
    }

    private func row(_ item: CogSetting) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t(item.en, item.zh)).font(.system(size: 12))
                Text(item.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(P.dim)
            }
            Spacer(minLength: 0)
            Picker("", selection: Binding(
                get: { model.choice(item.key, for: gameKey) },
                set: { model.setChoice(item.key, $0, for: gameKey) })) {
                ForEach(0..<item.choices.count, id: \.self) { i in
                    Text(zh ? item.zhChoices[i] : item.choices[i]).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
        .padding(.vertical, 7)
    }

    private var keybinds: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(P.line).padding(.top, 6)
            Text(model.t("Keyboard bindings", "键盘键位")).font(.system(size: 12, weight: .semibold))
            Text(model.t("Comma-separated alternatives; Shift+ / Ctrl+ / Alt+ prefixes; LMB / RMB / MMB. "
                         + "Leave a field empty to keep this game's default. A bare modifier key never fires.",
                         "逗号分隔多个键；支持 Shift+ / Ctrl+ / Alt+ 前缀和 LMB / RMB / MMB；"
                         + "留空即沿用本游戏默认值；单独绑 Shift / Alt / Ctrl 不会触发。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Keybinds.rows, id: \.cvar) { r in
                keybindRow(r)
                Divider().overlay(P.line)
            }
            HStack {
                Spacer()
                Button {
                    for r in Keybinds.rows { model.setText(r.cvar, "", for: gameKey) }
                } label: {
                    Text(model.t("Clear all key overrides", "清除全部键位改动")).font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
    }

    private func keybindRow(_ r: Keybinds.Row) -> some View {
        let value = model.text(r.cvar, for: gameKey)
        let bad = Keybinds.invalidTokens(value)
        let def = Keybinds.default(r, game: gameKey)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(r.button).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 38, alignment: .leading)
                    Text(model.t(r.action, r.zh)).font(.system(size: 12))
                }
                Text("\(r.cvar)  ·  default \(def.isEmpty ? "(none)" : def)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(P.dim)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                TextField(def.isEmpty ? model.t("no key", "未绑定") : def,
                          text: Binding(get: { model.text(r.cvar, for: gameKey) },
                                        set: { model.setText(r.cvar, $0, for: gameKey) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 190)
                if !bad.isEmpty {
                    Text(model.t("Unknown key: ", "未知键名：") + bad.joined(separator: ", "))
                        .font(.system(size: 9)).foregroundStyle(Color.red)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("Extra launch switches", "额外启动参数")).font(.system(size: 12, weight: .semibold))
            Text(model.t("One --switch=value per line; # starts a comment; {LOG} means the game's log folder. This is Windows' out/extra-args.txt.",
                         "每行一个 --参数=值；# 开头为注释；{LOG} 代表日志目录。对应 Windows 的 out/extra-args.txt。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { model.extra(for: gameKey) },
                set: { model.setExtra($0, for: gameKey) }))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 260)
                .background(P.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(P.line))
            Text(model.t("Any registered switch works here - including ones without a control above.",
                         "任何已注册的参数都可以在这里填写，包括上面没有控件的那些。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)

            Divider().overlay(P.line).padding(.vertical, 4)
            Text(model.t("Mods (folders, one per line, in load order)", "Mod（每行一个文件夹，按顺序加载）"))
                .font(.system(size: 12, weight: .semibold))
            Text(model.t("Each folder mirrors the game data folder; a later one wins. Sent as one --ue3_mods switch.",
                         "每个文件夹按游戏数据目录的结构摆放；靠后的优先。会合并成一个 --ue3_mods 参数。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { model.text("mods", for: gameKey) },
                set: { model.setText("mods", $0, for: gameKey) }))
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 90)
                .background(P.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(P.line))
            Button { addModFolder() } label: {
                Text(model.t("Add folder…", "添加文件夹…")).font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Divider().overlay(P.line).padding(.vertical, 4)
            Text(model.t("Player 1 gamertag", "1P 玩家代号")).font(.system(size: 12, weight: .semibold))
            Text(model.t("Up to 15 letters, digits and single spaces (--user_gamertag).",
                         "最多 15 个字母、数字和单个空格（--user_gamertag）。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)
            TextField(model.t("Leave empty for the game's own", "留空则沿用游戏默认"),
                      text: Binding(get: { model.text("gamertag", for: gameKey) },
                                    set: { model.setText("gamertag", $0, for: gameKey) }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11))

            Text(model.t("System Link peers (IPv4, one per line)", "System Link 对端 IP（每行一个）"))
                .font(.system(size: 12, weight: .semibold)).padding(.top, 4)
            Text(model.t("Comma-joined into --net_peer_ip; broadcasts go only to these PCs (VPN).",
                         "合并成 --net_peer_ip（逗号分隔）；广播只发给这些机器，适合 VPN。"))
                .font(.system(size: 10.5)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
            TextField(model.t("e.g. 10.0.0.2", "例如 10.0.0.2"),
                      text: Binding(get: { model.text("peerip", for: gameKey) },
                                    set: { model.setText("peerip", $0, for: gameKey) }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11))

            Divider().overlay(P.line).padding(.vertical, 4)
            Text(model.t("This Mac", "本机信息")).font(.system(size: 12, weight: .semibold))
            Text(HostCapabilities.summary(model.host))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("Windows disables options the machine cannot run; this port leaves every switch available — use this to judge for yourself.",
                         "Windows 启动器会按本机能力禁用选项；这里不禁用，请根据这些信息自行判断。"))
                .font(.system(size: 10)).foregroundStyle(P.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private func addModFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = model.t("Choose mod folders", "选择 Mod 文件夹")
        guard panel.runModal() == .OK else { return }
        var lines = model.text("mods", for: gameKey)
            .split(separator: "\n").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for url in panel.urls where !lines.contains(url.path) { lines.append(url.path) }
        model.setText("mods", lines.joined(separator: "\n"), for: gameKey)
    }
}

@main
struct COGBoxMacApp: App {
    var body: some Scene {
        WindowGroup("COGBox for macOS") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
