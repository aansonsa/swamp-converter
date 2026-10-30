import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// Frame extraction: the Studio preview scrubber, `video.thumbnail`, and the smart crop focus. AVFoundation first (mp4, mov, m4v ...);
// ffmpeg for mkv, webm, avi and anything AVFoundation cannot open. The container's rotation is always applied.

enum VideoFrameService {
    /// The frame at `time` seconds, longest side <= maxPixel, with the container's rotation applied.
    static func frame(of url: URL, at time: Double, maxPixel: Int) async throws -> CGImage {
        try Task.checkCancellation()
        if let img = try await nativeFrame(url, at: time, maxPixel: maxPixel) { return img }
        return try await ffmpegFrame(url, at: time, maxPixel: maxPixel)
    }

    static func nativeFrame(_ url: URL, at time: Double, maxPixel: Int) async throws -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }
        let dur = ((try? await asset.load(.duration))?.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var t = max(0, time)
        if let d = dur { t = min(t, max(0, d - 0.05)) }
        do {
            return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        } catch {
            try Task.checkCancellation()
            // Zero tolerance fails on some files (no exact sample); accept the nearest one.
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            return try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        }
    }

    static func ffmpegFrame(_ url: URL, at time: Double, maxPixel: Int) async throws -> CGImage {
        guard let ffmpeg = ToolLocator.shared.url(.ffmpeg) else { throw ConversionError.toolMissing(.ffmpeg) }
        let dir = AppPaths.makeTempDirectory(purpose: "frame")
        defer { AppPaths.removeTemp(dir) }
        let out = dir.appendingPathComponent("frame.png")
        let m = max(16, maxPixel)
        let scale = "scale=w='if(gt(iw,ih),min(iw,\(m)),-2)':h='if(gt(iw,ih),-2,min(ih,\(m)))'"
        let args = ["-hide_banner", "-nostdin", "-y", "-ss", VideoFFmpegArgs.ts(time), "-i", FFmpegCommand.safePath(url), "-frames:v", "1", "-an", "-sn", "-vf", scale, out.path]
        _ = try await ProcessRunner.run(ffmpeg, args, toolName: "ffmpeg", allowNonZeroExit: true)
        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConversionError.message(L10n("No picture could be read from the video at this time.", "В этот момент не удалось получить кадр из видео."))
        }
        return img
    }

    static func writePNG(_ image: CGImage, to url: URL) throws { try VideoOverlayRenderer.writePNG(image, to: url) }
}

/// Where the main subject of a clip is (faces first, then attention saliency), normalised with a top-left origin. Used by "Crop focus: Smart".
enum VideoSubjectFinder {
    static func center(url: URL, duration: Double?) async -> (x: Double, y: Double)? {
        guard let img = try? await VideoFrameService.frame(of: url, at: (duration ?? 0) * 0.5, maxPixel: 640) else { return nil }
        return await Task.detached(priority: .utility) { () -> (x: Double, y: Double)? in
            let handler = VNImageRequestHandler(cgImage: img)
            let faces = VNDetectFaceRectanglesRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([faces, saliency])
            var rects = (faces.results ?? []).map(\.boundingBox)
            if rects.isEmpty { rects = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox) }
            guard var box = rects.first else { return nil }
            for r in rects.dropFirst() { box = box.union(r) }
            return (x: Double(box.midX), y: Double(1 - box.midY))
        }.value
    }
}

/// `video.thumbnail`: one best frame, a frame at a time, a frame every N seconds, every scene change, or a contact sheet.
final class VideoFramesOperation: PerFileOperation, @unchecked Sendable {
    override func quickOverrides(settings: SettingsData) -> OptionValues { [:] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { VideoSchemas.frames(items: items) }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let o = VOpts(ctx.resolved)
        let mode = o.s(VideoKeys.frameMode).isEmpty ? "best" : o.s(VideoKeys.frameMode)
        let ext = o.s(VideoKeys.frameFormat) == "jpg" ? "jpg" : "png"
        let width = o.i(VideoKeys.frameWidth)
        let info = try await MediaProbe.probe(item.url, tools: ctx.tools)
        guard info.hasVideo else { throw ConversionError.message(L10n("This file has no video picture.", "В файле нет видеоизображения.")) }
        let duration = info.duration ?? 0
        let hasFF = ctx.tools.has(.ffmpeg)

        switch mode {
        case "best", "at":
            let t: Double
            if mode == "at" { t = o.time(VideoKeys.frameTime) ?? duration * 0.1 } else { t = min(duration * 0.05, 10) }
            let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: ext) { part in
                if hasFF {
                    try await runFFmpeg(single: item.url, at: t, best: mode == "best", ext: ext, width: width, output: part, duration: duration, ctx: ctx, progress: progress)
                } else {
                    let img = try await VideoFrameService.frame(of: item.url, at: t, maxPixel: width > 0 ? width : 8192)
                    try writeImage(img, ext: ext, to: part)
                }
            }
            return [url]
        case "every":
            let step = max(0.5, o.d(VideoKeys.frameEvery, 10))
            let count = max(1, min(o.i(VideoKeys.frameCount, 24), 500))
            let times = stride(from: 0.0, to: max(duration, 0.1), by: step).prefix(count).map { $0 }
            return [try await produceSet(item: item, ctx: ctx, ext: ext, progress: progress) { dir, name in
                if hasFF {
                    let vf = ["fps=1/\(VideoPlanner.num(step))"] + (width > 0 ? ["scale='min(\(width),iw)':-2"] : [])
                    try await self.runFFmpeg(multi: item.url, filters: vf, frames: count, ext: ext, pattern: Self.pattern(dir, name, ext), duration: duration, ctx: ctx, progress: progress)
                } else {
                    for (i, t) in times.enumerated() {
                        try ctx.checkCancelled()
                        let img = try await VideoFrameService.frame(of: item.url, at: t, maxPixel: width > 0 ? width : 8192)
                        try self.writeImage(img, ext: ext, to: dir.appendingPathComponent(String(format: "\(name) %03d.\(ext)", i + 1)))
                        progress.report(Double(i + 1) / Double(times.count))
                    }
                }
            }]
        case "scene":
            guard hasFF else { throw ConversionError.toolMissing(.ffmpeg) }
            let thr = o.d(VideoKeys.frameSceneThreshold, 0.4)
            let count = max(1, min(o.i(VideoKeys.frameCount, 24), 500))
            let vf = ["select='eq(n,0)+gt(scene,\(VideoPlanner.num(thr)))'"] + (width > 0 ? ["scale='min(\(width),iw)':-2"] : [])
            return [try await produceSet(item: item, ctx: ctx, ext: ext, progress: progress) { dir, name in
                try await self.runFFmpeg(multi: item.url, filters: vf, frames: count, ext: ext, pattern: Self.pattern(dir, name, ext), duration: duration, ctx: ctx, progress: progress)
            }]
        default: // sheet
            let count = max(1, min(o.i(VideoKeys.frameCount, 24), 500))
            let cols = Int(Double(count).squareRoot().rounded(.up)), rows = Int((Double(count) / Double(cols)).rounded(.up))
            let cell = width > 0 ? max(32, width / cols) : 320
            let url = try await ctx.produceFile(for: item, suffix: L10n("contact sheet", "контактный лист"), ext: ext) { part in
                guard hasFF else { throw ConversionError.toolMissing(.ffmpeg) }
                let rate = Double(count) / max(duration, 0.1)
                let vf = ["fps=\(VideoPlanner.num(rate))", "scale='min(\(cell),iw)':-2", "tile=\(cols)x\(rows):padding=4:margin=4:color=black"]
                var cmd = FFmpegCommand()
                cmd.inputs = [FFmpegInput(url: item.url)]
                cmd.videoFilters = vf
                cmd.outputs = [FFmpegOutput(url: part, options: ["-an", "-sn", "-frames:v", "1"] + imageCodecArgs(ext) + ["-f", "image2"])]
                try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: duration, progress: progress)
            }
            return [url]
        }
    }

    // MARK: Helpers

    /// The image2 output pattern: every "%" of the folder path is doubled so only our own %03d counts.
    static func pattern(_ dir: URL, _ escapedName: String, _ ext: String) -> URL {
        URL(fileURLWithPath: dir.path.replacingOccurrences(of: "%", with: "%%") + "/" + escapedName + " %03d." + ext)
    }

    private func imageCodecArgs(_ ext: String) -> [String] {
        ext == "jpg" ? ["-c:v", "mjpeg", "-q:v", "2", "-pix_fmt", "yuvj420p"] : ["-c:v", "png"]
    }

    private func produceSet(item: FileItem, ctx: OperationContext, ext: String, progress: ProgressSlice, _ body: @escaping (URL, String) async throws -> Void) async throws -> URL {
        let name = item.base.replacingOccurrences(of: "%", with: "%%")
        let rawName = item.base
        return try await ctx.produceFolder(for: item, suffix: L10n("frames", "кадры")) { dir in
            try await body(dir, name)
            // The name in the pattern escapes "%"; the files on disk must carry the real name.
            if rawName != name {
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(rawName) == false && f.hasPrefix(name) {
                    try? FileManager.default.moveItem(at: dir.appendingPathComponent(f), to: dir.appendingPathComponent(f.replacingOccurrences(of: name, with: rawName)))
                }
            }
            guard !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty else { throw ConversionError.noOutput }
        }
    }

    private func runFFmpeg(single input: URL, at t: Double, best: Bool, ext: String, width: Int, output: URL, duration: Double, ctx: OperationContext, progress: ProgressSlice) async throws {
        var cmd = FFmpegCommand()
        cmd.inputs = [FFmpegInput(url: input, options: t > 0.001 ? ["-ss", VideoFFmpegArgs.ts(t)] : [])]
        var vf: [String] = best ? ["thumbnail=150"] : []
        if width > 0 { vf.append("scale='min(\(width),iw)':-2") }
        cmd.videoFilters = vf
        cmd.outputs = [FFmpegOutput(url: output, options: ["-an", "-sn", "-frames:v", "1", "-update", "1"] + imageCodecArgs(ext) + ["-f", "image2"])]
        try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: nil, progress: progress)
        progress.report(1)
    }

    private func runFFmpeg(multi input: URL, filters: [String], frames: Int, ext: String, pattern: URL, duration: Double, ctx: OperationContext, progress: ProgressSlice) async throws {
        var cmd = FFmpegCommand()
        cmd.inputs = [FFmpegInput(url: input)]
        cmd.videoFilters = filters
        cmd.outputs = [FFmpegOutput(url: pattern, options: ["-an", "-sn", "-fps_mode", "vfr", "-frames:v", "\(frames)", "-start_number", "1"] + imageCodecArgs(ext) + ["-f", "image2"])]
        try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: duration, progress: progress)
    }

    private func writeImage(_ img: CGImage, ext: String, to url: URL) throws {
        let type = ext == "jpg" ? UTType.jpeg : UTType.png
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        CGImageDestinationAddImage(dest, img, ext == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
    }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        if tools.has(.ffmpeg) { return .available }
        let native: Set<String> = ["mp4", "mov", "m4v", "3gp", "3g2"]
        if items.allSatisfy({ native.contains($0.key) }) { return .available }
        return .unavailable(reason: Capabilities.reason(for: "tool.ffmpeg"), missing: [.ffmpeg])
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        let mode = options.string(VideoKeys.frameMode, "best")
        let name: [String: String] = ["best": L("Best frame", "Лучший кадр"), "at": L("One frame", "Один кадр"), "every": L("Every N seconds", "Каждые N секунд"),
                                      "scene": L("Scene changes", "Смены сцен"), "sheet": L("Contact sheet", "Контактный лист")]
        return [name[mode] ?? mode, options.string(VideoKeys.frameFormat, "png").uppercased()]
    }

    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        guard let item = items.first else { return nil }
        let t = time ?? (source?.duration ?? 0) * 0.1
        let img = try await VideoFrameService.frame(of: item.url, at: t, maxPixel: maxPixel)
        return OperationPreview(before: img, after: img, note: L10n("The picture that will be saved.", "Этот кадр будет сохранён."))
    }
}
