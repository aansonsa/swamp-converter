import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Subtitles inside a copy of the video.
//  * BURN-IN: this ffmpeg has no libass / drawtext, so every cue is drawn to a transparent PNG with CoreText, the PNGs are strung into one still-image
//    stream with the concat demuxer (blank frames in the gaps) and a single `overlay` filter puts that stream over the video. One filter, any number of cues.
//  * SOFT TRACK: the SRT is muxed as a subtitle stream (mov_text for MP4 / MOV, srt for MKV, webvtt for WebM) without touching the picture.

enum SubtitleOverlay {
    /// Draws one cue (1 or 2 lines) bottom-aligned into a transparent RGBA band of `width` x `height` pixels.
    static func render(_ text: String, width: Int, fontSize: CGFloat, height: Int) -> CGImage? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty, width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Shrink the cue when its widest line would leave the picture.
        func ctLine(_ s: String, _ size: CGFloat) -> CTLine {
            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
            return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        }
        var size = fontSize
        let widest = lines.map { CTLineGetTypographicBounds(ctLine($0, fontSize), nil, nil, nil) }.max() ?? 0
        let limit = Double(width) * 0.94
        if widest > limit { size = fontSize * CGFloat(limit / widest) }
        let lineHeight = size * 1.25
        ctx.setTextDrawingMode(.fillStroke)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.92))
        ctx.setLineWidth(max(size * 0.14, 1.5))
        ctx.setLineJoin(.round)
        for (i, s) in lines.reversed().enumerated() {
            let line = ctLine(s, size)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (CGFloat(width) - w) / 2, y: size * 0.45 + CGFloat(i) * lineHeight)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ConversionError.outputNotWritable(url) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.outputNotWritable(url) }
    }
}

enum SubtitleVideo {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]

    /// Same container as the source for MP4 / MOV / M4V / MKV, otherwise MP4.
    static func outputExtension(for item: FileItem) -> String { videoExtensions.contains(item.key) ? item.key : "mp4" }

    // MARK: Probing (size + duration)

    struct VideoGeometry { var width: Int; var height: Int; var duration: Double? }

    static func geometry(of url: URL, ctx: OperationContext) async -> VideoGeometry? {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            let d = (try? await asset.load(.duration))?.seconds
            if abs(r.width) >= 2, abs(r.height) >= 2 { return VideoGeometry(width: Int(abs(r.width)), height: Int(abs(r.height)), duration: d.flatMap { $0.isFinite ? $0 : nil }) }
        }
        guard let ffprobe = ctx.tools.url(.ffprobe) else { return nil }
        let args = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:stream_side_data=rotation:format=duration", "-of", "json", url.path]
        guard let text = SyncProcess.run(ffprobe, args, timeout: 15), let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first, var w = stream["width"] as? Int, var h = stream["height"] as? Int else { return nil }
        if let side = (stream["side_data_list"] as? [[String: Any]])?.first(where: { $0["rotation"] != nil }),
           let rot = (side["rotation"] as? NSNumber)?.intValue, abs(rot) % 180 == 90 { swap(&w, &h) }
        let d = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        return VideoGeometry(width: w, height: h, duration: d)
    }

    // MARK: Burn-in

    /// Writes a copy of `item` with `cues` drawn into the picture to `output` (a temp URL from `ctx.produceFile`). Re-encodes the video (H.264), copies the audio.
    static func burn(item: FileItem, cues: [(start: Double, end: Double, text: String)], output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
        guard !cues.isEmpty else { throw ConversionError.noText }
        guard let geo = await geometry(of: item.url, ctx: ctx) else {
            throw ConversionError.message(L10n("The video size could not be read, so the subtitles cannot be drawn.", "Не удалось определить размер видео, поэтому субтитры нельзя нарисовать."))
        }
        let work = ctx.tempDir.appendingPathComponent("burn-\(Util.hex8())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let width = geo.width - geo.width % 2
        let fontSize = CGFloat(width) * 0.032 * (geo.width >= geo.height ? 1 : 1.15)
        let band = Int(fontSize * 1.25 * 2 + fontSize * 0.9)
        guard let blank = SubtitleOverlay.render(" ", width: width, fontSize: fontSize, height: band) ?? emptyBand(width: width, height: band) else { throw ConversionError.noOutput }
        try SubtitleOverlay.writePNG(blank, to: work.appendingPathComponent("blank.png"))

        var list = ""
        func entry(_ file: String, _ duration: Double?) {
            list += "file '\(file)'\n"
            if let duration { list += String(format: "duration %.3f\n", duration) }
        }
        var cursor = 0.0
        for (i, cue) in cues.enumerated() {
            try ctx.checkCancelled()
            guard let image = SubtitleOverlay.render(cue.text, width: width, fontSize: fontSize, height: band) else { continue }
            let name = String(format: "cue%05d.png", i)
            try SubtitleOverlay.writePNG(image, to: work.appendingPathComponent(name))
            let start = max(cue.start, cursor)
            if start - cursor > 0.001 { entry("blank.png", start - cursor) }
            entry(name, max(cue.end - start, 0.04))
            cursor = max(cue.end, start + 0.04)
        }
        entry("blank.png", nil)
        let listURL = work.appendingPathComponent("cues.txt")
        try list.write(to: listURL, atomically: true, encoding: .utf8)

        let ext = output.pathExtension.lowercased()
        let audio: [String] = (videoExtensions.contains(item.key) && videoExtensions.contains(ext)) ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "256k"]
        var args = ["-hide_banner", "-nostdin", "-y", "-i", item.url.path, "-f", "concat", "-safe", "0", "-i", listURL.path,
                    "-filter_complex", "[0:v:0][1:v:0]overlay=0:H-h-0.03*H:format=auto:eof_action=pass[v]", "-map", "[v]", "-map", "0:a?", "-sn", "-dn"]
        args += try videoEncoderArguments(ctx: ctx, geometry: geo, sourceBytes: item.size)
        args += audio
        if ["mp4", "mov", "m4v"].contains(ext) { args += ["-movflags", "+faststart"] }
        args += ["-progress", "pipe:1", "-nostats", output.path]
        try await runFFmpeg(args, duration: geo.duration, ctx: ctx, progress: progress)
    }

    private static func emptyBand(width: Int, height: Int) -> CGImage? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// libx264 (CRF 18) when present; the hardware H.264 encoder when the context prefers it (Low Power Mode, heat) or libx264 is missing.
    static func videoEncoderArguments(ctx: OperationContext, geometry: VideoGeometry, sourceBytes: Int64?) throws -> [String] {
        let caps = Capabilities.shared
        func hardware() -> [String] {
            var bits = 10_000_000
            if let bytes = sourceBytes, let d = geometry.duration, d > 0 { bits = Int(Double(bytes) * 8 / d * 1.3) }
            bits = Swift.min(Swift.max(bits, 2_000_000), 60_000_000)
            return ["-c:v", "h264_videotoolbox", "-b:v", String(bits), "-pix_fmt", "yuv420p", "-allow_sw", "1"]
        }
        let x264 = ["-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p"]
        if ctx.preferHardware, caps.has("ff.enc.h264_videotoolbox") { return hardware() }
        if caps.has("ff.enc.libx264") { return x264 }
        if caps.has("ff.enc.h264_videotoolbox") { return hardware() }
        throw ConversionError.message(L10n("This ffmpeg has no H.264 encoder, so the subtitles cannot be burned in.", "В этой сборке ffmpeg нет кодировщика H.264, поэтому субтитры нельзя вжечь в видео."))
    }

    // MARK: Soft track

    static func addSoftTrack(item: FileItem, cues: [SubtitleCue], language: String, output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
        let ext = output.pathExtension.lowercased()
        let codec = ext == "mkv" ? "srt" : (ext == "webm" ? "webvtt" : "mov_text")
        let srt = ctx.tempDir.appendingPathComponent("soft-\(Util.hex8()).\(ext == "webm" ? "vtt" : "srt")")
        try SubtitleKit.serialize(cues, as: ext == "webm" ? .vtt : .srt).write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: srt) }
        let lang = Locale(identifier: language).language.languageCode?.identifier(.alpha3) ?? "und"
        let geo = await geometry(of: item.url, ctx: ctx)
        let args = ["-hide_banner", "-nostdin", "-y", "-i", item.url.path, "-i", srt.path, "-map", "0:v", "-map", "0:a?", "-map", "1:0",
                    "-c", "copy", "-c:s", codec, "-metadata:s:s:0", "language=\(lang)", "-progress", "pipe:1", "-nostats", output.path]
        try await runFFmpeg(args, duration: geo?.duration, ctx: ctx, progress: progress)
    }

    // MARK: ffmpeg

    private static func runFFmpeg(_ args: [String], duration: Double?, ctx: OperationContext, progress: ProgressSlice) async throws {
        try await ctx.runTool(.ffmpeg, args, onStdoutLine: { line in
            guard let d = duration, d > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress.report(Swift.min(us / 1_000_000 / d, 1))
        })
    }
}
