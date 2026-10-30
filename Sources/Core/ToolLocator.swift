import Foundation

// External tools. Everything works with macOS frameworks first; these tools are optional upgrades found
// through ToolLocator. The app NEVER downloads or installs anything: a missing tool disables the feature
// with a calm hint (see `Tool.installHint`).

enum Tool: String, CaseIterable, Codable, Sendable {
    // Optional (not shipped with macOS)
    case ffmpeg, ffprobe, pandoc, soffice, magick, cwebp, lame, flac, sox, zstd, xz, pdftotext
    // Downloader (network features, explicit consent): yt-dlp and the JavaScript runtimes it needs for YouTube.
    case ytdlp, deno, node, bun, quickjs
    // Built into macOS (always present)
    case sips, afconvert, afinfo, textutil, ditto, bsdtar, zip, unzip, iconutil, osascript, qlmanage

    /// Executable file names tried in each search folder, in order.
    var executableNames: [String] {
        switch self {
        case .magick: return ["magick"]   // the legacy 2015 x86_64 `convert` in /opt/ImageMagick is deliberately ignored (no HEIC/AVIF, wrong architecture)
        case .soffice: return ["soffice", "libreoffice"]
        case .ytdlp: return ["yt-dlp", "yt-dlp_macos"]
        case .quickjs: return ["qjs", "quickjs"]
        default: return [rawValue]
        }
    }

    /// Extra folders searched after the well-known bin folders (application bundles that are not on PATH).
    var extraDirectories: [String] {
        switch self {
        case .soffice:
            return ["/Applications/LibreOffice.app/Contents/MacOS", NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS"]
        default: return []
        }
    }

    /// Fixed absolute path for tools that ship with macOS; nil for optional tools.
    var systemPath: String? {
        switch self {
        case .sips, .afconvert, .afinfo, .textutil, .ditto, .bsdtar, .zip, .unzip, .iconutil, .osascript, .qlmanage:
            return "/usr/bin/\(rawValue)"
        default: return nil
        }
    }

    var isBuiltIn: Bool { systemPath != nil }

    var displayName: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .ffprobe: return "ffprobe"
        case .pandoc: return "Pandoc"
        case .soffice: return "LibreOffice"
        case .magick: return "ImageMagick"
        case .cwebp: return "cwebp"
        case .ytdlp: return "yt-dlp"
        case .quickjs: return "QuickJS"
        default: return rawValue
        }
    }

    /// Text shown next to a disabled control. The command is only displayed (copyable), never executed by the app.
    var installHint: L10n {
        switch self {
        case .ffmpeg, .ffprobe: return L10n("Install with: brew install ffmpeg", "Установка: brew install ffmpeg")
        case .pandoc: return L10n("Install with: brew install pandoc", "Установка: brew install pandoc")
        case .soffice: return L10n("Install with: brew install --cask libreoffice", "Установка: brew install --cask libreoffice")
        case .magick: return L10n("Install with: brew install imagemagick", "Установка: brew install imagemagick")
        case .cwebp: return L10n("Install with: brew install webp", "Установка: brew install webp")
        case .lame: return L10n("Install with: brew install lame", "Установка: brew install lame")
        case .flac: return L10n("Install with: brew install flac", "Установка: brew install flac")
        case .sox: return L10n("Install with: brew install sox", "Установка: brew install sox")
        case .zstd: return L10n("Install with: brew install zstd", "Установка: brew install zstd")
        case .xz: return L10n("Install with: brew install xz", "Установка: brew install xz")
        case .pdftotext: return L10n("Install with: brew install poppler", "Установка: brew install poppler")
        case .ytdlp: return L10n("Install it in Settings > Downloader (explicit download from the official release), or: brew install yt-dlp",
                                 "Установите в Настройки > Загрузка (явная загрузка с официального релиза) или: brew install yt-dlp")
        case .deno: return L10n("Install with: brew install deno", "Установка: brew install deno")
        case .node: return L10n("Install with: brew install node", "Установка: brew install node")
        case .bun: return L10n("Install with: brew install oven-sh/bun/bun", "Установка: brew install oven-sh/bun/bun")
        case .quickjs: return L10n("Install with: brew install quickjs", "Установка: brew install quickjs")
        default: return L10n("Part of macOS", "Входит в macOS")
        }
    }

    /// Argument that prints the version.
    var versionArguments: [String]? {
        switch self {
        case .ffmpeg, .ffprobe, .magick, .cwebp: return ["-version"]
        case .pandoc, .flac, .sox, .zstd, .xz, .lame, .ytdlp, .deno, .node, .bun, .quickjs: return ["--version"]
        case .pdftotext: return ["-v"]
        default: return nil   // soffice starts a full app; built-ins need no version
        }
    }
}

enum ToolSource: String, Sendable { case userOverride, bundled, userFolder, system, homebrew, path }

/// One search folder of the locator: the production default, nothing, or a fixed folder (tests use fake tools in a temp folder).
enum ToolRoot: Sendable, Equatable { case standard, none, folder(String) }

/// Where `ToolLocator` looks after the user override, in precedence order: bundled, user folder, well-known folders, application bundles, PATH.
/// Production uses `.standard`; tests pass their own folders so they never depend on what is installed on the Mac.
struct ToolSearchRoots: Sendable {
    /// `.standard` = `<app>/Contents/Resources/tools`.
    var bundled: ToolRoot = .standard
    /// `.standard` = `~/Library/Application Support/Swamp Converter/tools` (`AppPaths.userToolsDir`).
    var userFolder: ToolRoot = .standard
    var wellKnown: [String] = ToolLocator.wellKnownDirs
    /// `Tool.extraDirectories` (LibreOffice.app ...).
    var extraDirectories = true
    /// `.standard` = the `PATH` of this process; `.folder` may hold several folders separated by `:`.
    var path: ToolRoot = .standard

    static let standard = ToolSearchRoots()
    /// Searches nothing: every optional tool is missing (the built-in macOS tools are still found at their fixed paths).
    static let empty = ToolSearchRoots(bundled: .none, userFolder: .none, wellKnown: [], extraDirectories: false, path: .none)
}

struct ToolInfo: Sendable {
    let tool: Tool
    let url: URL
    let source: ToolSource
    var path: String { url.path }
}

final class ToolLocator: ObservableObject, @unchecked Sendable {
    static let shared = ToolLocator()

    private let lock = NSLock()
    private var cache: [Tool: ToolInfo?] = [:]
    private var versions: [String: String] = [:]
    /// Bumped by `refresh()`: a version probe that was running while the tool was replaced must not store (or return) what the OLD file printed.
    private var epoch = 0
    private var overrides: [String: String] = [:]
    private let roots: ToolSearchRoots

    init(roots: ToolSearchRoots = .standard) { self.roots = roots }

    /// Bumped by `refresh()`; Settings > Tools observes it.
    @Published private(set) var generation = 0

    /// Fixed search folders after the user override / bundled / user folder.
    static let wellKnownDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/ImageMagick/bin"]

    /// User-chosen absolute paths per tool (key = `Tool.rawValue`). Set from AppSettings.
    func setUserOverrides(_ map: [String: String]) {
        lock.lock(); overrides = map; cache.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.generation += 1 }
    }

    /// Forget every cached lookup ("Check Again").
    func refresh() {
        lock.lock(); cache.removeAll(); versions.removeAll(); epoch += 1; lock.unlock()
        Capabilities.shared.invalidate()
        DispatchQueue.main.async { self.generation += 1 }
    }

    func find(_ tool: Tool) -> ToolInfo? {
        lock.lock()
        if let hit = cache[tool] { lock.unlock(); return hit }
        let ov = overrides[tool.rawValue]
        lock.unlock()
        let found = locate(tool, override: ov)
        lock.lock(); cache[tool] = .some(found); lock.unlock()
        return found
    }

    func has(_ tool: Tool) -> Bool { find(tool) != nil }
    func url(_ tool: Tool) -> URL? { find(tool)?.url }

    /// The tool's URL or `ConversionError.toolMissing`.
    func require(_ tool: Tool) throws -> URL {
        guard let u = url(tool) else { throw ConversionError.toolMissing(tool) }
        return u
    }

    /// Missing optional tools out of `tools` (empty = all present).
    func missing(_ tools: [Tool]) -> [Tool] { tools.filter { !has($0) } }

    private func locate(_ tool: Tool, override: String?) -> ToolInfo? {
        let fm = FileManager.default
        func ok(_ p: String) -> Bool { fm.isExecutableFile(atPath: p) && !isDirectory(p) }
        if let sys = tool.systemPath { return ok(sys) ? ToolInfo(tool: tool, url: URL(fileURLWithPath: sys), source: .system) : nil }
        if let o = override, !o.isEmpty, ok(o) { return ToolInfo(tool: tool, url: URL(fileURLWithPath: o), source: .userOverride) }
        var dirs: [(String, ToolSource)] = []
        switch roots.bundled {
        case .standard: if let res = Bundle.main.resourceURL?.appendingPathComponent("tools").path { dirs.append((res, .bundled)) }
        case .folder(let f): dirs.append((f, .bundled))
        case .none: break
        }
        switch roots.userFolder {
        case .standard: dirs.append((AppPaths.userToolsDir.path, .userFolder))
        case .folder(let f): dirs.append((f, .userFolder))
        case .none: break
        }
        for d in roots.wellKnown { dirs.append((d, d.contains("homebrew") ? .homebrew : .system)) }
        if roots.extraDirectories { for d in tool.extraDirectories { dirs.append((d, .system)) } }
        let pathValue: String
        switch roots.path {
        case .standard: pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        case .folder(let f): pathValue = f
        case .none: pathValue = ""
        }
        for d in pathValue.split(separator: ":") { dirs.append((String(d), .path)) }
        for (dir, src) in dirs {
            for name in tool.executableNames {
                let p = (dir as NSString).appendingPathComponent(name)
                if ok(p) { return ToolInfo(tool: tool, url: URL(fileURLWithPath: p), source: src) }
            }
        }
        return nil
    }

    private func isDirectory(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    /// First line of `--version`, cached by path until `refresh()`. Blocks up to ~3 s the first time; call off the main thread.
    /// A probe that overlaps a `refresh()` (the tool was just replaced by an update) is run again, so neither the cache nor the caller keeps the old file's answer.
    func version(of tool: Tool) -> String? {
        guard let args = tool.versionArguments else { return nil }
        var line: String?
        for _ in 0..<3 {
            lock.lock(); let started = epoch; lock.unlock()
            guard let info = find(tool) else { return nil }
            lock.lock(); if let v = versions[info.path] { lock.unlock(); return v }; lock.unlock()
            let text = SyncProcess.run(info.url, args, timeout: 3, environment: childEnvironment(), sandboxed: false)
            line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
            guard let found = line else { return nil }
            lock.lock(); let unchanged = epoch == started; if unchanged { versions[info.path] = found }; lock.unlock()
            if unchanged { return found }
        }
        return line
    }

    /// `PATH` for child processes: folders of the located tools + system folders (GUI apps get a minimal PATH,
    /// and bsdtar needs zstd/lz4 on it). The order follows `find`: the person's own choices and the app's tools folder come before Homebrew, so a child that looks a
    /// tool up by name (yt-dlp asking for a JavaScript runtime) gets the same copy the app would use.
    var childPath: String {
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var dirs: [String] = []
        func add(_ d: String) { if !dirs.contains(d) && !system.contains(d) { dirs.append(d) } }
        let located = Tool.allCases.compactMap { find($0) }
        for i in located where i.source == .userOverride || i.source == .bundled || i.source == .userFolder { add(i.url.deletingLastPathComponent().path) }
        for d in roots.wellKnown where FileManager.default.fileExists(atPath: d) { add(d) }
        for i in located { add(i.url.deletingLastPathComponent().path) }
        return (dirs + system).joined(separator: ":")
    }

    /// Environment for every child process: controlled PATH, UTF-8 locale.
    func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = childPath
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        for (k, v) in extra { env[k] = v }
        return env
    }
}
