import Foundation

// Output location, naming, collision handling and atomic writes (spec/catalog.md section 3).
//  * collision-safe naming "name (2).ext", decided at move time
//  * engines write to a hidden sibling ".base.xxxxxxxx.part.ext" and the final rename happens last
//  * on any error or cancellation the partial is removed -- no partial file is ever left behind
//  * every final output is registered in OwnOutputs at the moment of the rename (watched-folder loop prevention)

enum OutputDirMode: String, Codable, Sendable { case sameAsSource, subfolder, custom }
enum OutputCollision: String, Codable, Sendable { case number, replace, skip }
enum AfterFinish: String, Codable, Sendable { case nothing, reveal, open, notify }

/// Where and how results are written. Global default lives in AppSettings; Studio can override per job.
struct OutputRules: Codable, Equatable, Sendable {
    var dirMode: OutputDirMode = .sameAsSource
    /// Folder name for `.subfolder` mode.
    var subfolderName: String = "Converted"
    /// Absolute path for `.custom` mode.
    var customDir: String? = nil
    /// File-name template. Tokens: {name} {suffix} {preset} {codec} {res} {width} {height} {fps} {quality}
    /// {container} {date} {time}. Unknown tokens are removed. The extension is added by the engine.
    var nameTemplate: String = "{name}"
    var collision: OutputCollision = .number
    var keepDates: Bool = true
    var trashSource: Bool = false
    var verify: Bool = true
    var after: AfterFinish = .nothing

    static let `default` = OutputRules()
}

enum OutputPaths {
    // MARK: Unique names

    /// `dir/base.ext`, else `dir/base (2).ext`, `(3)` ... (checks files AND folders). Never overwrites.
    static func unique(dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func candidate(_ n: Int) -> URL {
            let b = n == 1 ? base : "\(base) (\(n))"
            return dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)")
        }
        var n = 1
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    /// Same for folders: `name`, `name (2)`, ...
    static func uniqueDirectory(dir: URL, name: String) -> URL { unique(dir: dir, base: name, ext: "") }

    // MARK: Output directory

    /// Folder for results of `source` according to `rules` (created on demand). A dropped folder's results go to its parent.
    static func outputDirectory(for source: FileItem, rules: OutputRules) throws -> URL {
        let base = source.isDirectory ? source.parent : source.parent
        let dir: URL
        switch rules.dirMode {
        case .sameAsSource: dir = base
        case .subfolder: dir = base.appendingPathComponent(Util.safeFileName(rules.subfolderName, fallback: "Converted"), isDirectory: true)
        case .custom:
            guard let c = rules.customDir, !c.isEmpty else { dir = base; break }
            dir = URL(fileURLWithPath: c, isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw ConversionError.outputNotWritable(dir) }
        guard FileManager.default.isWritableFile(atPath: dir.path) else { throw ConversionError.outputNotWritable(dir) }
        return dir
    }

    // MARK: Names

    /// Expands the template. `{name}` is the source base name, `{suffix}` the localised tool suffix.
    /// Unknown or empty tokens vanish; empty parentheses and doubled spaces left behind are cleaned.
    static func expandTemplate(_ template: String, tokens: [String: String]) -> String {
        var out = template
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        var all = tokens
        let now = Date()
        df.dateFormat = "yyyy-MM-dd"; if all["date"] == nil { all["date"] = df.string(from: now) }
        df.dateFormat = "HH.mm.ss"; if all["time"] == nil { all["time"] = df.string(from: now) }
        let regex = try? NSRegularExpression(pattern: "\\{([a-zA-Z]+)\\}")
        let ns = out as NSString
        let matches = regex?.matches(in: out, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches.reversed() {
            let key = ns.substring(with: m.range(at: 1))
            let value = all[key] ?? ""
            out = (out as NSString).replacingCharacters(in: m.range, with: value)
        }
        out = out.replacingOccurrences(of: "()", with: "").replacingOccurrences(of: "( )", with: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespaces)
        return Util.safeFileName(out, fallback: tokens["name"] ?? "file")
    }

    /// `name` for conversions, `name (suffix)` for tools -- the default naming when no template is set.
    static func defaultTemplate(hasSuffix: Bool) -> String { hasSuffix ? "{name} ({suffix})" : "{name}" }

    /// Hidden in-flight names: `.base.8hex.part.ext`. Watched folders and `OwnOutputs` must ignore these.
    static func isInFlightName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.lowercased().contains(".part")
    }

    // MARK: Atomic produce

    /// Creates `dir`, gives `body` a hidden temp path `dir/.base.xxxxxxxx.part.ext`, then moves the result to a
    /// collision-free final name according to `rules.collision`. The temp is removed on every exit path.
    /// Throws `ConversionError.noOutput` when `body` returned without creating the file.
    static func produceFile(dir: URL, base: String, ext: String, collision: OutputCollision = .number,
                            _ body: (URL) async throws -> Void) async throws -> URL {
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw ConversionError.outputNotWritable(dir) }
        let temp = dir.appendingPathComponent(".\(base).\(Util.hex8()).part\(ext.isEmpty ? "" : "." + ext)")
        defer { try? fm.removeItem(at: temp) }
        try await body(temp)
        try Task.checkCancellation()
        guard fm.fileExists(atPath: temp.path) else { throw ConversionError.noOutput }
        let final = try moveIntoPlace(temp, dir: dir, base: base, ext: ext, collision: collision)
        OwnOutputs.shared.register(final)
        return final
    }

    /// Folder results (PDF pages, extracted archives): built in a hidden `.name.xxxxxxxx.part` folder, renamed at the end.
    static func produceFolder(dir: URL, name: String, collision: OutputCollision = .number,
                              _ body: (URL) async throws -> Void) async throws -> URL {
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw ConversionError.outputNotWritable(dir) }
        let temp = dir.appendingPathComponent(".\(name).\(Util.hex8()).part", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try await body(temp)
        try Task.checkCancellation()
        let final = try moveIntoPlace(temp, dir: dir, base: name, ext: "", collision: collision)
        OwnOutputs.shared.register(final)
        return final
    }

    /// Choosing the final name and moving the file there is ONE step under a lock: two jobs finishing at the same moment (a custom output folder, two
    /// folders holding a file of the same name, the same file dropped twice) must not both pick `name (2).ext`. Only a rename happens inside the lock.
    private static let finalizeLock = NSLock()
    private static func moveIntoPlace(_ temp: URL, dir: URL, base: String, ext: String, collision: OutputCollision) throws -> URL {
        finalizeLock.lock(); defer { finalizeLock.unlock() }
        let final = try resolveFinal(dir: dir, base: base, ext: ext, collision: collision)
        try FileManager.default.moveItem(at: temp, to: final)
        return final
    }

    private static func resolveFinal(dir: URL, base: String, ext: String, collision: OutputCollision) throws -> URL {
        let fm = FileManager.default
        let plain = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        switch collision {
        case .number: return unique(dir: dir, base: base, ext: ext)
        case .skip:
            if fm.fileExists(atPath: plain.path) { throw ConversionError.skippedExisting(plain) }
            return plain
        case .replace:
            if fm.fileExists(atPath: plain.path) {
                var trashed: NSURL?
                try fm.trashItem(at: plain, resultingItemURL: &trashed)   // never unlink: the old file goes to the Trash
            }
            return plain
        }
    }
}

/// Registry of files this app produced, checked by watched folders so results never trigger new jobs.
/// Entries expire after 30 minutes. Paths are compared after resolving symlinks (/var vs /private/var).
/// Memory is bounded: expired entries are dropped at most every few seconds, and a flood (a watched folder converting thousands of files)
/// keeps only the newest `capacity` entries.
final class OwnOutputs: @unchecked Sendable {
    static let shared = OwnOutputs()
    static let lifetime: TimeInterval = 30 * 60
    static let capacity = 10_000
    private let lock = NSLock()
    private struct Entry { var date: Date; var sequence: UInt64 }
    private var entries: [String: Entry] = [:]
    private var directories: [String: Int] = [:]
    private var lastPrune = Date.distantPast
    private var sequence: UInt64 = 0

    private func norm(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }

    func register(_ url: URL) {
        let key = norm(url)
        lock.lock(); sequence += 1; entries[key] = Entry(date: Date(), sequence: sequence); prune(); lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        let key = norm(url)
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return false }
        return Date().timeIntervalSince(entry.date) < Self.lifetime   // exact even between prunes
    }

    /// Number of remembered paths (tests, diagnostics).
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// While a job writes into `dir`, anything appearing there counts as ours.
    func beginWriting(to dir: URL) { let k = norm(dir); lock.lock(); directories[k, default: 0] += 1; lock.unlock() }
    func endWriting(to dir: URL) {
        let k = norm(dir)
        lock.lock(); if let n = directories[k] { directories[k] = n > 1 ? n - 1 : nil }; lock.unlock()
    }
    func isWriting(in dir: URL) -> Bool { let k = norm(dir); lock.lock(); defer { lock.unlock() }; return directories[k] != nil }

    /// Caller holds the lock.
    private func prune(now: Date = Date()) {
        guard entries.count > Self.capacity || now.timeIntervalSince(lastPrune) >= 5 else { return }
        lastPrune = now
        let cutoff = now.addingTimeInterval(-Self.lifetime)
        entries = entries.filter { $0.value.date > cutoff }
        if entries.count > Self.capacity {
            let keep = Self.capacity * 3 / 4
            let newest = entries.sorted { $0.value.sequence > $1.value.sequence }.prefix(keep)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
