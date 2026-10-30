import Foundation
import CryptoKit

// Where a download lives while it runs, and how finished files reach the output folder.
//
//   <output folder>/.swampdl-<8 hex>/        hidden work area, named after (link, format, mode): a retry of the same download finds its partials
//       tmp/                                  yt-dlp's `-P temp:` (.part, .ytdl, fragments)
//       out/                                  yt-dlp's `-P home:` (finished files, before they get their final names)
//
// Everything in a work area was created by this app, so removing it never touches the user's files. Finished files are moved into the output
// folder with collision-safe names (`name (2).ext`, or replace / skip according to the output rules) and their sidecars (.srt) follow them.

/// The default folders of finished downloads.
enum DownloadFolders {
    /// Tests redirect the Movies / Music roots so nothing is ever written into the real home folder.
    nonisolated(unsafe) static var rootsOverride: (video: URL, audio: URL)?

    static func video() -> URL { rootsOverride?.video ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Swamp Converter", isDirectory: true) }
    static func audio() -> URL { rootsOverride?.audio ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Swamp Converter", isDirectory: true) }

    /// `settings.downloader.folder` (with "~" expanded), else the Movies / Music folder. `override` is the folder of the job's own option.
    static func resolve(audioOnly: Bool, settingsFolder: String?, override: String? = nil) -> URL {
        for candidate in [override, settingsFolder] {
            guard let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { continue }
            let path = (c as NSString).expandingTildeInPath
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return audioOnly ? audio() : video()
    }
}

/// File kinds by extension (yt-dlp output names are ASCII extensions).
enum DownloadFileKinds {
    static let video: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v", "avi", "flv", "ts", "3gp", "ogv"]
    static let audio: Set<String> = ["m4a", "mp3", "opus", "flac", "ogg", "wav", "aac", "oga", "weba"]
    static let subtitles: Set<String> = ["srt", "vtt", "ass", "ttml", "lrc"]
    static let partial: Set<String> = ["part", "ytdl", "temp", "tmp"]
    static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }
    static func isVideo(_ url: URL) -> Bool { video.contains(ext(url)) }
    static func isAudio(_ url: URL) -> Bool { audio.contains(ext(url)) }
    static func isMedia(_ url: URL) -> Bool { isVideo(url) || isAudio(url) }
    static func isPartial(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return partial.contains(ext(url)) || n.contains(".part-frag") || n.hasSuffix(".part") || n.contains(".ytdl")
    }
}

struct DownloadWorkArea: Sendable {
    let root: URL
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var out: URL { root.appendingPathComponent("out", isDirectory: true) }

    static let prefix = ".swampdl-"

    /// The area for one download: the same link, selector and mode always map to the same folder, so a retry resumes.
    static func make(in outputDirectory: URL, key: String) -> DownloadWorkArea {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return DownloadWorkArea(root: outputDirectory.appendingPathComponent(prefix + hex, isDirectory: true))
    }

    func create() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
        } catch { throw ConversionError.outputNotWritable(root.deletingLastPathComponent()) }
    }

    /// Removes the whole area (never anything else: the root must be a `.swampdl-` folder).
    func remove() {
        guard root.lastPathComponent.hasPrefix(Self.prefix) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Removes the area when it holds nothing at all (a failure before the first byte). Partials are kept: the next try resumes from them.
    func removeIfEmpty() {
        let fm = FileManager.default
        let any = [tmp, out].contains { dir in
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
            return en.nextObject() != nil
        }
        if !any { remove() }
    }

    /// Removes the area when it holds no finished file (an aborted run that left only partials, or nothing).
    func removeIfNothingFinished() {
        if DownloadWorkArea.finishedFiles(in: out).isEmpty { remove() }
    }

    /// Regular, non-hidden, non-partial files below `dir`, oldest name first.
    static func finishedFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, !DownloadFileKinds.isPartial(u) else { continue }
            out.append(u)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Work areas left by crashed runs: older than `age` seconds and without a finished file. Called once per run for the output folder.
    static func cleanStale(in outputDirectory: URL, olderThan age: TimeInterval = 14 * 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: outputDirectory.path) else { return }
        for n in names where n.hasPrefix(prefix) {
            let area = DownloadWorkArea(root: outputDirectory.appendingPathComponent(n, isDirectory: true))
            let modified = (try? area.root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { area.removeIfNothingFinished() }
        }
    }

    /// Finished files that are inside `out` (a path outside is ignored: yt-dlp's list is data, not an instruction).
    func confined(_ paths: [String]) -> [URL] {
        let base = out.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var seen = Set<String>()
        var result: [URL] = []
        for p in paths {
            let u = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL
            guard u.path.hasPrefix(base), FileManager.default.fileExists(atPath: u.path), !DownloadFileKinds.isPartial(u), seen.insert(u.path).inserted else { continue }
            result.append(URL(fileURLWithPath: p).standardizedFileURL)
        }
        return result
    }

    /// Path of `file` relative to `out` ("Mix/01 - a.mp4"), or just its name.
    func relativePath(of file: URL) -> String {
        let base = out.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let p = file.resolvingSymlinksInPath().standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : file.lastPathComponent
    }
}

enum DownloadPlacer {
    /// Subtitle / thumbnail files that belong to `main`: same stem followed by ".lang.ext" (title [id].en.srt).
    static func sidecars(of main: URL, in files: [URL]) -> [URL] {
        let stem = main.deletingPathExtension().lastPathComponent
        return files.filter { $0 != main && !DownloadFileKinds.isMedia($0) && $0.lastPathComponent.hasPrefix(stem + ".") }
    }

    /// Moves `raw` into `directory` with the output rules' collision handling. Returns the final URL.
    /// `base` replaces the file's own stem (the converted file keeps the download's name).
    static func place(_ raw: URL, into directory: URL, base: String? = nil, rules: OutputRules) async throws -> URL {
        let fm = FileManager.default
        let stem = base ?? raw.deletingPathExtension().lastPathComponent
        return try await OutputPaths.produceFile(dir: directory, base: stem, ext: raw.pathExtension, collision: rules.collision) { temp in
            try fm.moveItem(at: raw, to: temp)
        }
    }

    /// Moves the sidecars of `raw` next to its final file: "<final stem>.en.srt".
    static func placeSidecars(_ sidecars: [URL], rawStem: String, finalStem: String, into directory: URL) {
        let fm = FileManager.default
        for s in sidecars {
            let name = s.lastPathComponent
            let rest = String(name.dropFirst(rawStem.count))            // ".en.srt"
            var target = directory.appendingPathComponent(finalStem + rest)
            if fm.fileExists(atPath: target.path) {
                let ext = (rest as NSString).pathExtension
                let mid = (rest as NSString).deletingPathExtension
                target = OutputPaths.unique(dir: directory, base: finalStem + mid, ext: ext)
            }
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.moveItem(at: s, to: target)
            OwnOutputs.shared.register(target)
        }
    }

    /// Non-async rescue used when a job is cancelled: every FINISHED file of the work area goes to the output folder (never overwriting),
    /// the partials and the area itself are removed. Safe to call from a cancelled task.
    static func salvage(_ area: DownloadWorkArea, into directory: URL) -> [URL] {
        let fm = FileManager.default
        var placed: [URL] = []
        for f in DownloadWorkArea.finishedFiles(in: area.out) {
            let rel = area.relativePath(of: f)
            let dir = directory.appendingPathComponent((rel as NSString).deletingLastPathComponent, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = OutputPaths.unique(dir: dir, base: f.deletingPathExtension().lastPathComponent, ext: f.pathExtension)
            if (try? fm.moveItem(at: f, to: target)) != nil {
                OwnOutputs.shared.register(target)
                if DownloadFileKinds.isMedia(target) { placed.append(target) }
            }
        }
        area.remove()
        return placed
    }
}
