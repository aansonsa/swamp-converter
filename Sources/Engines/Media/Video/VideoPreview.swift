import Foundation
import CoreGraphics
import CoreImage
import ImageIO

// The Studio preview: the frame at a time as it is (before) and with the current picture settings applied (after). With ffmpeg the "after" frame
// goes through the very same filter chain the encode uses (one frame, a few hundred milliseconds); without it, CoreImage applies the plan.
// Nothing is written next to the user's files.

enum VideoPreview {
    /// Filters that need more than one frame or change timing: they have no meaning for a still preview.
    static func stillSafe(_ filters: [String]) -> [String] {
        filters.filter { f in
            !(f.hasPrefix("reverse") || f.hasPrefix("setpts") || f.hasPrefix("fps=") || f.hasPrefix("minterpolate") || f.hasPrefix("framerate") || f.hasPrefix("fade")
              || f.hasPrefix("decimate") || f.hasPrefix("fieldmatch") || f.hasPrefix("deshake"))
        }
    }

    static func make(item: FileItem, options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        let info = try await VideoMediaCache.shared.info(for: item.url)
        guard info.hasVideo else { return nil }
        let duration = info.duration ?? 0
        let t = max(0, min(time ?? duration * 0.1, max(0, duration - 0.05)))
        let before = try await VideoFrameService.frame(of: item.url, at: t, maxPixel: maxPixel)
        try Task.checkCancellation()
        let r = VideoSourceBridge.resolve(options, source: source)
        let toolset = MediaToolset.current
        guard let plan = try? VideoPlanBuilder.build(options: r, source: info, toolset: toolset), !plan.noVideo, plan.container != "gif" else {
            return OperationPreview(before: before, after: before, note: nil)
        }
        let hasOverlays = !plan.overlays.isEmpty
        var after: CGImage? = nil
        if toolset.hasFFmpeg, plan.videoCodec != "copy" {
            after = try? await viaFFmpeg(item.url, plan: plan, at: t, maxPixel: maxPixel)
        }
        if after == nil, plan.backend == .avfoundation || !toolset.hasFFmpeg {
            // No ffmpeg: the same CoreImage steps the export uses.
            let big = try await VideoFrameService.frame(of: item.url, at: t, maxPixel: max(maxPixel, 1920))
            after = scaledToFit(VideoCI.cgImage(VideoCI.process(CIImage(cgImage: big), picture: plan.picture, outputSize: nil)), maxPixel: maxPixel)
        }
        let note: L10n? = hasOverlays ? L10n("The preview shows the picture settings; watermark and subtitles are added when converting.", "В предпросмотре видны настройки картинки; водяной знак и субтитры добавляются при конвертации.") : nil
        return OperationPreview(before: before, after: after ?? before, note: note)
    }

    static func viaFFmpeg(_ url: URL, plan: VideoEncodePlan, at t: Double, maxPixel: Int) async throws -> CGImage? {
        guard let ffmpeg = ToolLocator.shared.url(.ffmpeg) else { return nil }
        let pre = Array(plan.videoFilters.dropLast(plan.postOverlayFilterCount))
        let m = max(16, maxPixel)
        let vf = (stillSafe(pre) + ["scale=w='if(gt(iw,ih),min(iw,\(m)),-2)':h='if(gt(iw,ih),-2,min(ih,\(m)))'"]).joined(separator: ",")
        let dir = AppPaths.makeTempDirectory(purpose: "preview")
        defer { AppPaths.removeTemp(dir) }
        let out = dir.appendingPathComponent("after.png")
        var args = ["-hide_banner", "-nostdin", "-y"]
        if plan.noAutoRotate { args.append("-noautorotate") }
        args += ["-ss", VideoFFmpegArgs.ts(t), "-i", FFmpegCommand.safePath(url), "-frames:v", "1", "-an", "-sn", "-vf", vf, out.path]
        _ = try await ProcessRunner.run(ffmpeg, args, toolName: "ffmpeg", allowNonZeroExit: true)
        guard let src = CGImageSourceCreateWithURL(out as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func scaledToFit(_ img: CGImage?, maxPixel: Int) -> CGImage? {
        guard let img else { return nil }
        let longest = max(img.width, img.height)
        guard longest > maxPixel else { return img }
        let f = Double(maxPixel) / Double(longest)
        let w = max(1, Int(Double(img.width) * f)), h = max(1, Int(Double(img.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
