import Foundation

// yt-dlp tool management. The app NEVER ships or fetches yt-dlp silently: `ToolLocator` finds an existing one (PATH, Homebrew, the user
// folder ~/Library/Application Support/Swamp Converter/tools); `install()` is the ONE explicit way to get it (a button in Settings >
// Downloader and in the first-use sheet) and goes through `NetworkGate`. The install / update code lives in YtDlpInstall.swift.

/// A JavaScript runtime yt-dlp needs for full YouTube support (with yt-dlp-ejs): deno, node, bun or quickjs.
struct JSRuntime: Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable { case deno, node, bun, quickjs }
    var kind: Kind
    var url: URL
    var version: String?
    /// The value for yt-dlp's `--js-runtimes` ("deno:/opt/homebrew/bin/deno", "node:/opt/homebrew/bin/node", "bun:...", "quickjs:...").
    var argument: String { "\(kind.rawValue):\(url.path)" }
}

struct YtDlpStatus: Equatable, Sendable {
    var url: URL?
    var version: String?
    var source: ToolSource?
    var jsRuntime: JSRuntime?
    var isInstalled: Bool { url != nil }
}

/// What the Downloader settings page shows when no JS runtime exists: an explanation and an equally explicit install route.
enum JSRuntimeAdvice {
    /// Plain-words explanation ("YouTube needs a small JavaScript runtime. node and bun are common; ...").
    static var explanation: L10n {
        L10n("YouTube needs a JavaScript runtime to unlock all video qualities. Install deno, node, bun or quickjs, for example with Homebrew: brew install deno.",
             "Для YouTube нужен JavaScript-движок, чтобы открыть все варианты качества. Установите deno, node, bun или quickjs, например через Homebrew: brew install deno.")
    }
    /// Command shown (copyable, never executed by the app).
    static let installCommand = "brew install deno"
    /// Shown when a runtime exists but is older than yt-dlp's documented minimum.
    static func tooOld(_ kind: JSRuntime.Kind) -> L10n {
        L10n("The installed \(kind.rawValue) is too old for YouTube. Update it, or install deno: \(installCommand).",
             "Установленный \(kind.rawValue) слишком старый для YouTube. Обновите его или установите deno: \(installCommand).")
    }
}

/// Finds a JS runtime without any actor requirement (used by capability checks too).
enum JSRuntimeDetector {
    /// Folders a GUI app does not have on its PATH but where these runtimes usually live.
    static var extraSearchDirectories: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.deno/bin", "\(home)/.bun/bin", "/opt/homebrew/opt/node/bin", "/opt/homebrew/opt/deno/bin", "/usr/local/opt/node/bin"]
    }

    /// Order of preference: deno (yt-dlp's default), node, bun, quickjs.
    static let preference: [(Tool, JSRuntime.Kind)] = [(.deno, .deno), (.node, .node), (.bun, .bun), (.quickjs, .quickjs)]

    /// Every runtime that can be found, in order of preference. No process is started (cheap).
    static func detectAll(tools: ToolLocator = .shared) -> [JSRuntime] {
        let fm = FileManager.default
        var out: [JSRuntime] = []
        for (tool, kind) in preference {
            if let u = tools.url(tool) { out.append(JSRuntime(kind: kind, url: u, version: nil)); continue }
            let candidates = extraSearchDirectories.flatMap { dir in tool.executableNames.map { (dir as NSString).appendingPathComponent($0) } }
            if let p = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
                out.append(JSRuntime(kind: kind, url: URL(fileURLWithPath: p), version: nil))
            }
        }
        return out
    }

    /// The runtime yt-dlp is told to use. Cheap: fills no version (see `detectAll(withVersions:)`).
    static func detect(tools: ToolLocator = .shared) -> JSRuntime? { detectAll(tools: tools).first }

    /// Same, with `--version` read for each (starts up to four short processes: call off the main thread). The first runtime that meets
    /// the minimum version wins; if none does the first one is returned so the UI can say it is too old.
    static func detectBest(tools: ToolLocator = .shared) -> (runtime: JSRuntime, meetsMinimum: Bool)? {
        let all = detectAll(tools: tools).map { rt -> JSRuntime in
            var r = rt
            r.version = SyncProcess.run(rt.url, ["--version"], timeout: 3, sandboxed: false)?.split(whereSeparator: \.isNewline).first.map(String.init)
            return r
        }
        if let ok = all.first(where: { meetsMinimum($0) }) { return (ok, true) }
        return all.first.map { ($0, false) }
    }

    /// yt-dlp's documented minimums for the n-challenge solver: deno 2.0, node 20, bun 1.0.31, quickjs any.
    static func meetsMinimum(_ rt: JSRuntime) -> Bool {
        guard let v = rt.version else { return true }   // unknown: assume fine, yt-dlp will say otherwise
        let nums = versionNumbers(v)
        guard !nums.isEmpty else { return true }
        func atLeast(_ min: [Int]) -> Bool {
            for (i, m) in min.enumerated() {
                let x = i < nums.count ? nums[i] : 0
                if x != m { return x > m }
            }
            return true
        }
        switch rt.kind {
        case .deno: return atLeast([2, 0, 0])
        case .node: return atLeast([20, 0, 0])
        case .bun: return atLeast([1, 0, 31])
        case .quickjs: return true
        }
    }

    /// "v20.11.1" -> [20, 11, 1]; "deno 2.1.4 (stable, ...)" -> [2, 1, 4]; "Bun 1.1.0" -> [1, 1, 0].
    static func versionNumbers(_ text: String) -> [Int] {
        guard let r = text.range(of: "[0-9]+(\\.[0-9]+)*", options: .regularExpression) else { return [] }
        return text[r].split(separator: ".").compactMap { Int($0) }
    }
}

enum YtDlpUpdateOutcome: Equatable, Sendable {
    case alreadyLatest(version: String)
    case updated(from: String?, to: String)
}

/// Fetches bytes. The default implementation uses URLSession; tests inject a stub so NOTHING touches the network.
protocol DownloaderHTTP: Sendable {
    func data(from url: URL) async throws -> Data
    /// Streams a (possibly large) file to `destination`, reporting 0...1.
    func download(from url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws
    /// Follows redirects and returns the final URL ("releases/latest" -> ".../releases/tag/2026.10.20"). Additive requirement with a default.
    func finalURL(of url: URL) async throws -> URL
}

extension DownloaderHTTP {
    func finalURL(of url: URL) async throws -> URL { url }
}

@MainActor
final class YtDlpToolManager: ObservableObject {
    static let shared = YtDlpToolManager()

    @Published private(set) var status = YtDlpStatus()
    /// Replaceable in tests (stub fetcher serving fixture bytes).
    var http: DownloaderHTTP = URLSessionDownloaderHTTP()

    /// Release asset and checksum file of the official yt-dlp GitHub release (Unlicense). Both are fetched only by `install()`.
    static let assetURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    static let checksumsURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!
    static let latestReleaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!
    static let assetName = "yt-dlp_macos"
    /// Where `install()` puts the binary: AppPaths.userToolsDir / "yt-dlp".
    static var installURL: URL { AppPaths.userToolsDir.appendingPathComponent("yt-dlp") }

    /// Re-detects the tool and the JS runtime (no network). Forgets the tool lookup cache first, so a copy installed a moment ago is found.
    /// The version number is read in the background and published when known.
    func refresh() {
        ToolLocator.shared.refresh()
        status.version = nil      // the file may have been replaced (update): never show the old version number
        applyDetected()
    }

    /// Cheap detection from the current lookup cache: no process is started here.
    func applyDetected() {
        let info = ToolLocator.shared.find(.ytdlp)
        let sameTool = status.url == info?.url
        status = YtDlpStatus(url: info?.url, version: sameTool ? status.version : nil, source: info?.source, jsRuntime: detectJSRuntime())
        guard info != nil else { return }
        let expected = info?.url
        Task { @MainActor [weak self] in
            let probe = await Task.detached(priority: .utility) { (ToolLocator.shared.version(of: .ytdlp), JSRuntimeDetector.detectBest()) }.value
            guard let self, self.status.url == expected else { return }
            self.status.version = probe.0
            if let best = probe.1 { self.status.jsRuntime = best.runtime }
        }
    }

    /// First available runtime in the order deno, node, bun, quickjs (ToolLocator finds them in PATH / Homebrew).
    func detectJSRuntime() -> JSRuntime? { JSRuntimeDetector.detect() }

    /// The installed version string ("2026.10.20"), read from the tool when not known yet. Runs the tool off the main actor.
    func installedVersion() async -> String? {
        if let v = status.version { return v }
        let v = await Task.detached(priority: .utility) { ToolLocator.shared.version(of: .ytdlp) }.value
        if status.url != nil { status.version = v }
        return v
    }

    /// Lets the install / update code (another file) publish a status without exposing the setter.
    func publish(_ new: YtDlpStatus) { status = new }
}
