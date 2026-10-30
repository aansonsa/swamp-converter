import Foundation

// Capability ids answer "can this Mac do X right now?". Option fields and presets carry `requires: [String]`;
// a missing capability disables the control and shows why (never silently hides it).
//
// Built-in id families
//   tool.<name>         an optional/built-in tool is located           (tool.ffmpeg, tool.cwebp, tool.pandoc, ...)
//   ff.present          same as tool.ffmpeg
//   ff.enc.<encoder>    ffmpeg lists the encoder                       (ff.enc.libx265, ff.enc.libsvtav1, ff.enc.aac_at ...)
//   ff.filter.<name>    ffmpeg lists the filter                        (ff.filter.bwdif, ff.filter.zscale ...)
//   ff.mux.<name>       ffmpeg lists the muxer                         (ff.mux.webm, ff.mux.matroska ...)
//   native.<anything>   registered by an engine at startup with `Capabilities.shared.register(...)`
//                       e.g. native.imageio.write.heic, native.vision.lang.ru

struct FFmpegCapabilities: Codable, Sendable {
    var path: String
    var mtime: Double
    var size: Int64
    var version: String
    var encoders: Set<String>
    var filters: Set<String>
    var muxers: Set<String>
}

final class Capabilities: @unchecked Sendable {
    static let shared = Capabilities()

    private let lock = NSLock()
    private var custom: [String: @Sendable () -> Bool] = [:]
    private var customCache: [String: Bool] = [:]
    private var ffmpegCache: FFmpegCapabilities??

    /// Engines register native checks once at startup (cheap closures; results are cached until `invalidate`).
    func register(_ id: String, check: @escaping @Sendable () -> Bool) {
        lock.lock(); custom[id] = check; customCache[id] = nil; lock.unlock()
    }

    func invalidate() {
        lock.lock(); ffmpegCache = nil; customCache.removeAll(); lock.unlock()
    }

    func has(_ id: String) -> Bool {
        if id.hasPrefix("tool."), let t = Tool(rawValue: String(id.dropFirst(5))) { return ToolLocator.shared.has(t) }
        if id == "ff.present" { return ToolLocator.shared.has(.ffmpeg) }
        if id.hasPrefix("ff.enc.") { return ffmpeg()?.encoders.contains(String(id.dropFirst(7))) ?? false }
        if id.hasPrefix("ff.filter.") { return ffmpeg()?.filters.contains(String(id.dropFirst(10))) ?? false }
        if id.hasPrefix("ff.mux.") { return ffmpeg()?.muxers.contains(String(id.dropFirst(7))) ?? false }
        lock.lock()
        if let c = customCache[id] { lock.unlock(); return c }
        let check = custom[id]
        lock.unlock()
        guard let check else { return false }
        let v = check()
        lock.lock(); customCache[id] = v; lock.unlock()
        return v
    }

    /// True when the check registered for `id` has already run (its answer is cached). The self-tests use it to prove that registering an engine runs no check.
    func isEvaluated(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return customCache[id] != nil
    }

    /// True when every id is available.
    func hasAll(_ ids: [String]) -> Bool { ids.allSatisfy(has) }

    /// The first missing capability's user-facing reason ("Needs ffmpeg ..."), or nil if all present.
    func missingReason(_ ids: [String]) -> L10n? {
        guard let id = ids.first(where: { !has($0) }) else { return nil }
        return Capabilities.reason(for: id)
    }

    static func reason(for id: String) -> L10n {
        if id.hasPrefix("tool."), let t = Tool(rawValue: String(id.dropFirst(5))) {
            return L10n("Needs \(t.displayName) (not installed). \(t.installHint.en)", "Нужен \(t.displayName) (не установлен). \(t.installHint.ru)")
        }
        if id == "ff.present" || id.hasPrefix("ff.") {
            let what = id.split(separator: ".").last.map(String.init) ?? "ffmpeg"
            if id == "ff.present" { return L10n("Needs ffmpeg (not installed). Open Settings > Tools to see how to add it.", "Нужен ffmpeg (не установлен). Откройте Настройки > Инструменты, чтобы узнать, как его добавить.") }
            return L10n("Needs an ffmpeg build with \(what). Open Settings > Tools.", "Нужна сборка ffmpeg с поддержкой \(what). Откройте Настройки > Инструменты.")
        }
        return L10n("Not available on this Mac.", "Недоступно на этом Mac.")
    }

    // MARK: ffmpeg probing

    /// Parsed `-encoders/-filters/-muxers` of the located ffmpeg, cached in memory and in caps.json
    /// (keyed by path + mtime + size). Nil when ffmpeg is missing. Blocks the first time (~150 ms).
    func ffmpeg() -> FFmpegCapabilities? {
        lock.lock()
        if let c = ffmpegCache { lock.unlock(); return c }
        lock.unlock()
        let result = probeFFmpeg()
        lock.lock(); ffmpegCache = .some(result); lock.unlock()
        return result
    }

    private func probeFFmpeg() -> FFmpegCapabilities? {
        guard let info = ToolLocator.shared.find(.ffmpeg) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: info.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if let data = try? Data(contentsOf: AppPaths.capabilitiesCacheFile),
           let cached = try? JSONDecoder().decode(FFmpegCapabilities.self, from: data),
           cached.path == info.path, cached.mtime == mtime, cached.size == size { return cached }
        let env = ToolLocator.shared.childEnvironment()
        func list(_ flag: String) -> String { SyncProcess.run(info.url, ["-hide_banner", flag], timeout: 10, environment: env, sandboxed: false) ?? "" }
        let version = SyncProcess.run(info.url, ["-hide_banner", "-version"], timeout: 5, environment: env, sandboxed: false)?
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let caps = FFmpegCapabilities(
            path: info.path, mtime: mtime, size: size, version: version,
            encoders: Self.parseNames(list("-encoders"), flagWidth: 6),
            filters: Self.parseNames(list("-filters"), flagWidth: 3),
            muxers: Self.parseNames(list("-muxers"), flagWidth: 2))
        if let data = try? JSONEncoder().encode(caps) { try? data.write(to: AppPaths.capabilitiesCacheFile, options: .atomic) }
        return caps
    }

    /// Parses ffmpeg listing output: after the `------` line every row is ` <flags> <name> <description>`.
    static func parseNames(_ text: String, flagWidth: Int) -> Set<String> {
        var names = Set<String>()
        var inBody = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("------") { inBody = true; continue }
            guard inBody, line.hasPrefix(" ") else { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count <= max(flagWidth, 6) else { continue }
            // Muxer rows can list several names: "matroska,webm".
            for n in parts[1].split(separator: ",") { names.insert(String(n)) }
        }
        return names
    }
}
