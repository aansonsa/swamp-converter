import Foundation
import AVFoundation

// A thin, self-contained layer over ffprobe / ffmpeg for the fit engines. It deliberately does not depend on the internals of the media modules:
// the fit loop needs exact control over the argument list (two passes, bitrate corrections) and over the size of every attempt.

/// What the fit engines need to know about a video. Sizes are DISPLAY sizes (rotation applied), like the picture the viewer sees.
struct FitVideoInfo: Equatable, Sendable {
    var duration: Double
    var size: Int64
    var videoIndex: Int
    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String
    var pixelFormat: String
    var bitDepth: Int
    var isHDR: Bool
    var colorPrimaries: String?
    var colorTransfer: String?
    var colorSpace: String?
    var audioIndex: Int?
    var audioChannels: Int
    var audioKbps: Int?
    /// Audio streams beyond the first and subtitle streams: the fit keeps one soundtrack and no subtitles, and says so.
    var extraAudioStreams = 0
    var subtitleStreams = 0
    var hasAudio: Bool { audioIndex != nil }
}

enum FitProbe {
    /// ffprobe JSON of a video. Throws a calm message when the file has no picture or no length.
    static func video(_ url: URL, ctx: OperationContext) async throws -> FitVideoInfo {
        let json = try await ffprobeJSON(url, ctx: ctx)
        guard let info = parseVideo(json, fileSize: fileSize(url)) else {
            throw ConversionError.message(L10n("This file has no picture or its length is unknown, so it cannot be fitted to a size.",
                                               "В этом файле нет изображения или неизвестна длительность, поэтому уложить его в размер нельзя."))
        }
        return info
    }

    /// Duration in seconds of an audio file: AVFoundation for the formats it reads, ffprobe for the rest.
    static func audioDuration(_ url: URL, ctx: OperationContext) async -> Double? {
        if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 { return d }
        guard ctx.tools.has(.ffprobe), let json = try? await ffprobeJSON(url, ctx: ctx) else { return nil }
        let d = Double(((json["format"] as? [String: Any])?["duration"] as? String) ?? "") ?? 0
        return d > 0 ? d : nil
    }

    static func ffprobeJSON(_ url: URL, ctx: OperationContext) async throws -> [String: Any] {
        let out = try await ctx.runTool(.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path], captureStdout: true)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any] else {
            throw ConversionError.fileUnreadable(url)
        }
        return obj
    }

    /// Pure: ffprobe JSON -> FitVideoInfo (nil without a picture stream or a positive duration).
    static func parseVideo(_ json: [String: Any], fileSize: Int64) -> FitVideoInfo? {
        let format = json["format"] as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        func attached(_ s: [String: Any]) -> Bool { ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 1 }
        guard let v = streams.first(where: { ($0["codec_type"] as? String) == "video" && !attached($0) }) else { return nil }
        var duration = Double((format["duration"] as? String) ?? "") ?? 0
        if duration <= 0 { duration = Double((v["duration"] as? String) ?? "") ?? 0 }
        guard duration > 0 else { return nil }
        var w = v["width"] as? Int ?? 0, h = v["height"] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        var rotation = 0
        for sd in (v["side_data_list"] as? [[String: Any]]) ?? [] {
            if let r = sd["rotation"] as? Double { rotation = Int(r.rounded()) } else if let r = sd["rotation"] as? Int { rotation = r }
        }
        if rotation == 0, let r = (v["tags"] as? [String: Any])?["rotate"] as? String, let i = Int(r) { rotation = i }
        if abs(rotation) % 180 == 90 { swap(&w, &h) }
        let fps = fraction(v["avg_frame_rate"] as? String) ?? fraction(v["r_frame_rate"] as? String) ?? 30
        let pix = v["pix_fmt"] as? String ?? ""
        let depth = Int((v["bits_per_raw_sample"] as? String) ?? "") ?? (pix.contains("10") ? 10 : (pix.contains("12") ? 12 : 8))
        let trc = v["color_transfer"] as? String
        let hdr = trc == "smpte2084" || trc == "arib-std-b67"
        let audio = streams.filter { ($0["codec_type"] as? String) == "audio" }
        let a = audio.first
        var info = FitVideoInfo(duration: duration, size: Int64((format["size"] as? String) ?? "") ?? fileSize, videoIndex: v["index"] as? Int ?? 0,
                            width: w, height: h, fps: fps, videoCodec: v["codec_name"] as? String ?? "", pixelFormat: pix, bitDepth: depth, isHDR: hdr,
                            colorPrimaries: v["color_primaries"] as? String, colorTransfer: trc, colorSpace: v["color_space"] as? String,
                            audioIndex: a?["index"] as? Int, audioChannels: a?["channels"] as? Int ?? 2,
                            audioKbps: (Int((a?["bit_rate"] as? String) ?? "")).map { $0 / 1000 })
        info.extraAudioStreams = max(audio.count - 1, 0)
        info.subtitleStreams = streams.filter { ($0["codec_type"] as? String) == "subtitle" }.count
        return info
    }

    static func fraction(_ s: String?) -> Double? {
        guard let s else { return nil }
        let p = s.split(separator: "/")
        if p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d > 0, n > 0 { return n / d }
        if p.count == 1, let n = Double(p[0]), n > 0 { return n }
        return nil
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum FitFFmpeg {
    static let prefix = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"]

    /// Runs ffmpeg (arguments after the fixed prefix), reporting 0...1 of `duration` through `report`. Cancellation kills the process tree (ProcessRunner).
    static func run(_ arguments: [String], ctx: OperationContext, duration: Double, report: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await ctx.runTool(.ffmpeg, prefix + arguments, onStdoutLine: { line in
                guard duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                report(min(max(us / 1_000_000 / duration, 0), 0.99))
            })
        } catch ConversionError.toolFailed(_, _, let detail) where detail.contains("Unknown encoder") || detail.contains("Encoder not found") {
            throw ConversionError.message(L10n("This ffmpeg build cannot write the format needed here. Open Settings > Tools to see how to get a full build.",
                                               "Эта сборка ffmpeg не умеет писать нужный формат. Откройте Настройки > Инструменты, чтобы узнать, как получить полную сборку."))
        }
        report(1)
    }
}

/// Small helpers for attempt files: hidden siblings of the real temp file, so a finished attempt moves into place with a rename on the same volume
/// and the watched-folder guard (`isInFlightName`) ignores them.
enum FitFiles {
    static func attempt(beside temp: URL, _ index: Int, ext: String) -> URL {
        temp.deletingLastPathComponent().appendingPathComponent(".fit-\(Util.hex8())-\(index).part.\(ext)")
    }

    static func remove(_ url: URL?) {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Moves `from` onto `to` (replacing an existing file) -- the atomic last step of an attempt loop.
    static func place(_ from: URL, at to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.moveItem(at: from, to: to)
    }

    /// Copies an input that already fits, unchanged, as the result.
    static func copyUnchanged(_ input: FileItem, ext: String, suffix: L10n?, ctx: OperationContext) async throws -> URL {
        try await ctx.produceFile(for: input, suffix: suffix, ext: ext) { temp in
            try FileManager.default.copyItem(at: input.url, to: temp)
        }
    }
}

/// Where the names of the result come from: "clip (Discord 10 MB).mp4".
enum FitNaming {
    static func suffix(_ options: OptionValues) -> L10n {
        let id = options.string(FitKeys.target)
        if id == SizeTarget.customID {
            let mb = options.double(FitKeys.customMB, 10)
            return L10n(Util.safeSuffix(SizeTarget.formatMB(mb, russian: false)), Util.safeSuffix(SizeTarget.formatMB(mb, russian: true)))
        }
        return SizeTargetCatalog.target(id: id)?.suffix ?? L10n("fit", "до размера")
    }
}
