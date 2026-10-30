import Foundation

// Independent read-back tools for the conformance checks: `file`, `ffprobe`, `unzip`, `bsdtar`, `gzip`. They are used the way a reviewer with a shell would
// use them, never through the engines' own wrappers, so a bug shared by the writer and its wrapper cannot hide. Arguments are always arrays (no shell).

struct ProbeOutput {
    var status: Int32
    var output: String
    var error: String
    var timedOut = false
}

enum ExternalProbe {
    /// Runs `exe` and returns stdout and stderr separately. Kills the process after `timeout` seconds.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60, input: Data? = nil, environment: [String: String]? = nil, currentDirectory: URL? = nil) -> ProbeOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = currentDirectory
        p.arguments = args
        p.environment = environment ?? ToolLocator.shared.childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        ProcessStats.noteStart()
        do { try p.run() } catch { return ProbeOutput(status: -1, output: "", error: "cannot start \(exe): \(error)") }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input { try? inPipe.fileHandleForWriting.write(contentsOf: input); try? inPipe.fileHandleForWriting.close() }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { timedOut = true; p.terminate(); Thread.sleep(forTimeInterval: 0.1); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        p.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        return ProbeOutput(status: p.terminationStatus, output: String(decoding: outData, as: UTF8.self), error: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    }

    /// Path of an installed tool (nil when absent) as the app's own locator sees it.
    static func path(_ tool: Tool) -> String? { ToolLocator.shared.find(tool)?.path }

    static func has(_ tool: Tool) -> Bool { path(tool) != nil }

    /// An executable by name in the usual tool folders (for helpers the app itself never uses, such as dwebp).
    static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// The first `bytes` bytes a decompressor writes for `url` (the process is stopped as soon as it has enough).
    static func decompressedPrefix(_ url: URL, tool: String, args: [String], bytes: Int) -> [UInt8] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args + [url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        ProcessStats.noteStart()
        guard (try? p.run()) != nil else { return [] }
        var got = Data()
        let h = out.fileHandleForReading
        while got.count < bytes {
            guard let chunk = try? h.read(upToCount: bytes - got.count), !chunk.isEmpty else { break }
            got.append(chunk)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return Array(got)
    }

    // MARK: file(1)

    /// `file --mime-type -b`: libmagic's opinion, a second independent detector.
    static func fileMime(_ url: URL) -> String? {
        let r = run("/usr/bin/file", ["--mime-type", "-b", url.path], timeout: 10)
        return r.status == 0 ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func fileDescription(_ url: URL) -> String? {
        let r = run("/usr/bin/file", ["-b", url.path], timeout: 10)
        return r.status == 0 ? r.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: Archives

    /// `unzip -tq`: every member decompresses and its CRC matches.
    static func zipIsIntact(_ url: URL) -> (ok: Bool, message: String) {
        let r = run("/usr/bin/unzip", ["-tq", url.path], timeout: 60)
        return (r.status == 0, (r.output + r.error).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `bsdtar -tf`: member names (any archive libarchive reads).
    static func archiveMembers(_ url: URL) -> [String]? {
        let r = run("/usr/bin/bsdtar", ["-tf", url.path], timeout: 60)
        guard r.status == 0 else { return nil }
        return r.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// `bsdtar -tvf` parsed: mode (octal), size and name per member.
    static func archiveListing(_ url: URL) -> [(mode: UInt16, size: Int64, name: String, isDirectory: Bool, isSymlink: Bool)]? {
        let r = run("/usr/bin/bsdtar", ["-tvf", url.path], timeout: 60)
        guard r.status == 0 else { return nil }
        var rows: [(UInt16, Int64, String, Bool, Bool)] = []
        for line in r.output.split(separator: "\n", omittingEmptySubsequences: true) {
            // "-rw-r--r--  0 user group    12 Oct 24 12:00 name with spaces"
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9, parts[0].count == 10 else { continue }
            let perm = String(parts[0])
            var mode: UInt16 = 0
            let bits = Array(perm.dropFirst())
            for (i, ch) in bits.enumerated() where ch != "-" { mode |= UInt16(1 << (8 - i)) }
            var name = String(parts[8])
            let isLink = perm.first == "l"
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[name.startIndex..<arrow.lowerBound]) }
            rows.append((mode, Int64(parts[4]) ?? 0, name, perm.first == "d", isLink))
        }
        return rows.map { (mode: $0.0, size: $0.1, name: $0.2, isDirectory: $0.3, isSymlink: $0.4) }
    }

    /// Extracts `url` with bsdtar into a fresh folder under `into` and returns it (nil on failure).
    static func extractWithTar(_ url: URL, into dir: URL) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = run("/usr/bin/bsdtar", ["-xpf", url.path, "-C", dir.path], timeout: 120)
        return r.status == 0 ? dir : nil
    }
}

// MARK: - ffprobe

struct FFProbeStream: Sendable {
    var index = 0
    var type = ""
    var codec = ""
    var profile = ""
    var codecTag = ""
    var width: Int?
    var height: Int?
    var pixFmt: String?
    var fps: Double?
    var frames: Int?
    var sampleRate: Int?
    var channels: Int?
    var channelLayout: String?
    var duration: Double?
    var startTime: Double?
    var bitRate: Int?
    var bitsPerSample: Int?
    var colorTransfer: String?
    var colorPrimaries: String?
    var colorSpace: String?
    var rotation: Int?
    var tags: [String: String] = [:]
    var isAttachedPicture = false
}

struct FFProbeInfo: Sendable {
    var formatNames: [String] = []
    var duration: Double?
    var bitRate: Int?
    var size: Int64?
    var tags: [String: String] = [:]
    var chapters = 0
    var streams: [FFProbeStream] = []

    var video: [FFProbeStream] { streams.filter { $0.type == "video" && !$0.isAttachedPicture } }
    var audio: [FFProbeStream] { streams.filter { $0.type == "audio" } }
    var subtitles: [FFProbeStream] { streams.filter { $0.type == "subtitle" } }
    func hasFormat(_ names: String...) -> Bool { names.contains { formatNames.contains($0) } }
}

extension ExternalProbe {
    /// `ffprobe -show_format -show_streams` as structured data (`countFrames` decodes the whole video stream: only for small fixtures).
    static func ffprobe(_ url: URL, countFrames: Bool = false, timeout: TimeInterval = 120) -> FFProbeInfo? {
        guard let exe = path(.ffprobe) else { return nil }
        var args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters"]
        if countFrames { args.append("-count_frames") }
        let r = run(exe, args + [url.path], timeout: timeout)
        guard r.status == 0, let obj = (try? JSONSerialization.jsonObject(with: Data(r.output.utf8))) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? String).flatMap(Double.init) ?? (v as? Int).map(Double.init) }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } ?? (v as? Double).map { Int($0) } }
        var info = FFProbeInfo()
        if let f = obj["format"] as? [String: Any] {
            info.formatNames = ((f["format_name"] as? String) ?? "").split(separator: ",").map(String.init)
            info.duration = num(f["duration"])
            info.bitRate = int(f["bit_rate"])
            info.size = (f["size"] as? String).flatMap { Int64($0) }
            info.tags = (f["tags"] as? [String: Any])?.compactMapValues { $0 as? String }.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value } ?? [:]
        }
        info.chapters = (obj["chapters"] as? [Any])?.count ?? 0
        for s in (obj["streams"] as? [[String: Any]]) ?? [] {
            var st = FFProbeStream()
            st.index = int(s["index"]) ?? 0
            st.type = (s["codec_type"] as? String) ?? ""
            st.codec = (s["codec_name"] as? String) ?? ""
            st.profile = (s["profile"] as? String) ?? ""
            st.codecTag = (s["codec_tag_string"] as? String) ?? ""
            st.width = int(s["width"]); st.height = int(s["height"])
            st.pixFmt = s["pix_fmt"] as? String
            if let rate = s["avg_frame_rate"] as? String {
                let p = rate.split(separator: "/")
                if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b > 0 { st.fps = a / b }
            }
            st.frames = int(s["nb_read_frames"]) ?? int(s["nb_frames"])
            st.sampleRate = int(s["sample_rate"]); st.channels = int(s["channels"])
            st.channelLayout = s["channel_layout"] as? String
            st.duration = num(s["duration"]); st.startTime = num(s["start_time"]); st.bitRate = int(s["bit_rate"])
            st.bitsPerSample = int(s["bits_per_raw_sample"]) ?? int(s["bits_per_sample"])
            st.colorTransfer = s["color_transfer"] as? String
            st.colorPrimaries = s["color_primaries"] as? String
            st.colorSpace = s["color_space"] as? String
            st.tags = (s["tags"] as? [String: Any])?.compactMapValues { $0 as? String }.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value } ?? [:]
            if let side = s["side_data_list"] as? [[String: Any]], let rot = side.compactMap({ int($0["rotation"]) }).first { st.rotation = rot }
            if let t = st.tags["rotate"], let rot = Int(t) { st.rotation = rot }
            if let d = s["disposition"] as? [String: Any], int(d["attached_pic"]) == 1 { st.isAttachedPicture = true }
            info.streams.append(st)
        }
        return info
    }
}
