import Foundation

// Ogg Vorbis through `sox`, for Macs whose ffmpeg has no libvorbis (ffmpeg's built-in Vorbis encoder is experimental and measurably poor: about 6 dB SNR
// at 160 kbit/s on a test mix where libvorbis and Opus reach 25 dB). The signal work happens first (native engine or ffmpeg filters) and ends in a float32
// WAV; sox only encodes. An `.ogg` file therefore always holds real Vorbis.

enum AudSox {
    private static let probed = Locked<[String: Bool]>([:])

    private static var cacheFile: URL { AppPaths.capabilitiesCacheFile.deletingLastPathComponent().appendingPathComponent("sox-caps.json") }

    /// Does this sox build write Ogg Vorbis? Asked once per executable (path + modification date + size) by encoding 50 ms of silence into a temporary
    /// file; the answer is kept in memory and on disk, so the wheel never waits for a process start.
    static func supportsVorbis(_ exe: URL) -> Bool {
        if let known = probed.value[exe.path] { return known }
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let key = "\(exe.path)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)"
        if let data = try? Data(contentsOf: cacheFile), let saved = try? JSONDecoder().decode([String: Bool].self, from: data), let v = saved[key] {
            probed.withLock { $0[exe.path] = v }
            return v
        }
        let ok = probeNow(exe)
        probed.withLock { $0[exe.path] = ok }
        let merged = ((try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]).merging([key: ok]) { $1 }
        if let data = try? JSONEncoder().encode(merged) { try? data.write(to: cacheFile, options: .atomic) }
        return ok
    }

    private static func probeNow(_ exe: URL) -> Bool {
        let dir = AppPaths.makeTempDirectory(purpose: "soxprobe")
        defer { AppPaths.removeTemp(dir) }
        let out = dir.appendingPathComponent("probe.ogg")
        let text = SyncProcess.run(exe, ["-n", "-r", "8000", "-c", "1", "-C", "1", out.path, "trim", "0", "0.05"], timeout: 10)
        return text != nil && OggMagic.looksLikeOgg(out)
    }

    /// Vorbis quality (-1 ... 10) whose nominal bit rate is `kbps` (libvorbis nominal rates for 44.1 kHz stereo, interpolated between the steps).
    static func quality(forKbps kbps: Int) -> Double {
        let steps: [(q: Double, kbps: Double)] = [(-1, 45), (0, 64), (1, 80), (2, 96), (3, 112), (4, 128), (5, 160), (6, 192), (7, 224), (8, 256), (9, 320), (10, 500)]
        let k = Double(kbps)
        if k <= steps[0].kbps { return -1 }
        for i in 1..<steps.count where k <= steps[i].kbps {
            let a = steps[i - 1], b = steps[i]
            return a.q + (b.q - a.q) * (k - a.kbps) / (b.kbps - a.kbps)
        }
        return 10
    }

    /// `sox in.wav -C q ... out.ogg`. Tags travel as Vorbis comments (UTF-8); an empty `--comment` drops anything the input carried.
    static func arguments(plan: AudPlan, tags: AudTags, input: URL, output: URL) -> [String] {
        let q = plan.useQuality ? AudQuality.vorbisQ(plan.quality) : quality(forKbps: plan.kbps)
        var a = ["-V1", "-D", input.path, "-t", "ogg", "-C", String(format: "%.2f", q), "--comment", ""]
        let fields: [(String, String)] = [("TITLE", tags.title), ("ARTIST", tags.artist), ("ALBUM", tags.album), ("ALBUMARTIST", tags.albumArtist), ("DATE", tags.year),
                                         ("TRACKNUMBER", tags.track), ("TRACKTOTAL", tags.trackTotal), ("DISCNUMBER", tags.disc), ("GENRE", tags.genre),
                                         ("COMPOSER", tags.composer), ("COMMENT", tags.comment)]
        for (k, v) in fields where !v.isEmpty { a += ["--add-comment", "\(k)=\(v)"] }
        a.append(output.path)
        return a
    }
}

/// Tiny byte check so the sox probe does not depend on any other module.
enum OggMagic {
    static func looksLikeOgg(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)).map { String(decoding: $0, as: UTF8.self) == "OggS" } ?? false
    }
}
