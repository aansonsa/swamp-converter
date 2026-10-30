import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Burned-in subtitles and text watermarks without libass / drawtext (this ffmpeg has neither): each cue is rendered with CoreText into a
// transparent RGBA PNG, a concat list gives every picture its time window, and `overlay` composites it (spec/handbrake.md 2.7, verified:
// the cue shows only inside its window). Image watermarks go through the same `overlay` stage.

struct PreparedOverlay: Sendable {
    var input: FFmpegInput
    /// Builds the filter fragment: (index of this overlay's input, label of the running video, label of the result).
    var stage: @Sendable (_ inputIndex: Int, _ inLabel: String, _ outLabel: String) -> String
}

enum VideoOverlayRenderer {
    // MARK: Entry

    static func prepare(_ overlays: [VideoOverlay], plan: VideoEncodePlan, tempDirectory: URL) throws -> [PreparedOverlay] {
        var out: [PreparedOverlay] = []
        let fmt = overlayFormat(plan.pixelFormat)
        for (n, ov) in overlays.enumerated() {
            switch ov {
            case .watermarkImage(let file, let pct, let opacity, let pos, let margin):
                let png = try watermarkPNG(from: file, tempDirectory: tempDirectory, name: "wm-\(n).png")
                let outW = plan.picture.outputSize?.w ?? 1280
                let w = max(16, Int((Double(outW) * pct / 100 / 2).rounded()) * 2)
                let alpha = max(0, min(1, opacity))
                out.append(PreparedOverlay(input: FFmpegInput(url: png), stage: { i, a, b in
                    "[\(i):v]scale=\(w):-2,format=rgba,colorchannelmixer=aa=\(VideoPlanner.num(alpha))[wm\(i)];[\(a)][wm\(i)]overlay=\(position(pos, margin: margin)):format=\(fmt):eof_action=repeat[\(b)]"
                }))
            case .watermarkText(let text, let pct, let opacity, let pos, let margin):
                let outW = plan.picture.outputSize?.w ?? 1280
                guard let img = renderWatermarkText(text, widthPixels: max(24, Int(Double(outW) * pct / 100))) else { continue }
                let url = tempDirectory.appendingPathComponent("wmt-\(n).png")
                try writePNG(img, to: url)
                let alpha = max(0, min(1, opacity))
                out.append(PreparedOverlay(input: FFmpegInput(url: url), stage: { i, a, b in
                    "[\(i):v]format=rgba,colorchannelmixer=aa=\(VideoPlanner.num(alpha))[wm\(i)];[\(a)][wm\(i)]overlay=\(position(pos, margin: margin)):format=\(fmt):eof_action=repeat[\(b)]"
                }))
            case .burnIn(let cues, let style):
                guard let size = plan.picture.outputSize else { continue }
                let list = try writeCueTimeline(cues, style: style, size: size, plan: plan, tempDirectory: tempDirectory, prefix: "burn\(n)")
                out.append(PreparedOverlay(input: FFmpegInput(url: list, options: ["-f", "concat", "-safe", "0"]), stage: { i, a, b in
                    "[\(i):v]format=rgba[sb\(i)];[\(a)][sb\(i)]overlay=0:0:format=\(fmt):eof_action=pass[\(b)]"
                }))
            }
        }
        return out
    }

    /// The `overlay` blend format that keeps the picture's own pixel format: with `auto` ffmpeg converts the whole frame through a different chroma
    /// format and every edge of the picture changes slightly; with the matching format only the pixels under the overlay change.
    static func overlayFormat(_ pixFmt: String?) -> String {
        guard let p = pixFmt else { return "yuv420" }
        let ten = p.contains("10")
        if p.hasPrefix("yuv444") || p.hasPrefix("yuvj444") { return ten ? "yuv444p10" : "yuv444" }
        if p.hasPrefix("yuv422") || p.hasPrefix("p210") { return ten ? "yuv422p10" : "yuv422" }
        if p.hasPrefix("yuv420") || p.hasPrefix("yuvj420") || p.hasPrefix("p010") { return ten ? "yuv420p10" : "yuv420" }
        return "auto"
    }

    /// `overlay` x:y for tl / tr / bl / br / center with a margin in pixels.
    static func position(_ pos: String, margin m: Int) -> String {
        switch pos {
        case "tl": return "\(m):\(m)"
        case "tr": return "W-w-\(m):\(m)"
        case "bl": return "\(m):H-h-\(m)"
        case "center": return "(W-w)/2:(H-h)/2"
        default: return "W-w-\(m):H-h-\(m)"
        }
    }

    // MARK: Cue timeline

    /// The segments of the burned-in track in OUTPUT time: (start, end, text). Overlapping cues are merged into one text; times are
    /// shifted by the trim start and divided by the speed factor.
    static func segments(_ cues: [VideoCue], trimStart: Double, speed: Double, outputDuration: Double?) -> [(start: Double, end: Double, text: String)] {
        let shifted: [VideoCue] = cues.compactMap { c in
            let a = (c.start - trimStart) / speed, b = (c.end - trimStart) / speed
            if b <= 0 { return nil }
            if let d = outputDuration, a >= d { return nil }
            return VideoCue(start: max(0, a), end: b, text: c.text)
        }
        var bounds = Set<Double>()
        for c in shifted { bounds.insert((c.start * 1000).rounded() / 1000); bounds.insert((c.end * 1000).rounded() / 1000) }
        let sorted = bounds.sorted()
        var result: [(Double, Double, String)] = []
        for i in 0..<max(0, sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            let mid = (a + b) / 2
            let active = shifted.filter { $0.start <= mid && $0.end >= mid }.map { $0.text }
            if !active.isEmpty { result.append((a, b, active.joined(separator: "\n"))) }
        }
        return result
    }

    static func writeCueTimeline(_ cues: [VideoCue], style: VideoBurnStyle, size: (w: Int, h: Int), plan: VideoEncodePlan, tempDirectory: URL, prefix: String) throws -> URL {
        let segs = segments(cues, trimStart: plan.trimStart, speed: plan.picture.speed, outputDuration: plan.outputDuration)
        guard !segs.isEmpty else { throw ConversionError.noSubtitles }
        let blankName = "\(prefix)-blank.png"
        try writePNG(blankImage(size: size), to: tempDirectory.appendingPathComponent(blankName))
        var names: [String: String] = [:]
        var list = "ffconcat version 1.0\n"
        var cursor = 0.0
        func fmt(_ t: Double) -> String { String(format: "%.3f", max(0.001, t)) }
        for s in segs {
            if s.start > cursor + 0.0005 { list += "file '\(blankName)'\nduration \(fmt(s.start - cursor))\n" }
            let name: String
            if let n = names[s.text] { name = n } else {
                name = "\(prefix)-\(names.count).png"
                names[s.text] = name
                if let img = renderCue(s.text, style: style, size: size) { try writePNG(img, to: tempDirectory.appendingPathComponent(name)) }
                else { try writePNG(blankImage(size: size), to: tempDirectory.appendingPathComponent(name)) }
            }
            list += "file '\(name)'\nduration \(fmt(s.end - max(s.start, cursor)))\n"
            cursor = max(cursor, s.end)
        }
        list += "file '\(blankName)'\n"   // the concat demuxer needs a closing entry to honour the last duration
        let url = tempDirectory.appendingPathComponent("\(prefix).ffconcat")
        try Data(list.utf8).write(to: url)
        return url
    }

    // MARK: Rendering

    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return CGColor(red: 1, green: 1, blue: 1, alpha: alpha) }
        return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static func font(_ name: String, size: CGFloat) -> NSFont {
        if name.isEmpty || name.hasPrefix("SF Pro") || name.lowercased() == "system" { return NSFont.systemFont(ofSize: size, weight: .semibold) }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func blankImage(size: (w: Int, h: Int)) -> CGImage {
        context(max(2, size.w), max(2, size.h))!.makeImage()!
    }

    /// A full-frame transparent picture with the cue text placed according to the style.
    static func renderCue(_ text: String, style: VideoBurnStyle, size: (w: Int, h: Int)) -> CGImage? {
        let W = max(2, size.w), H = max(2, size.h)
        guard let ctx = context(W, H) else { return nil }
        let px = max(8, CGFloat(H) * CGFloat(style.sizePercent) / 100)
        let f = font(style.font, size: px)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: para, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let maxW = CGFloat(W) * 0.9
        let setter = CTFramesetterCreateWithAttributedString(str)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: str.length), nil, CGSize(width: maxW, height: CGFloat.greatestFiniteMagnitude), nil)
        let textW = min(maxW, ceil(fit.width) + 2), textH = ceil(fit.height) + 2
        let margin = CGFloat(H) * CGFloat(style.margin) / 100
        let x = (CGFloat(W) - textW) / 2
        let y: CGFloat
        switch style.position {
        case "top": y = CGFloat(H) - margin - textH
        case "middle": y = (CGFloat(H) - textH) / 2
        default: y = margin
        }
        let rect = CGRect(x: x, y: max(0, y), width: textW, height: textH)
        if style.box {
            ctx.setFillColor(CGColor(gray: 0, alpha: CGFloat(style.boxOpacity) / 100))
            let pad = px * 0.35
            let r = rect.insetBy(dx: -pad, dy: -pad * 0.6)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: px * 0.3, cornerHeight: px * 0.3, transform: nil)); ctx.fillPath()
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        if style.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: CGFloat(style.shadow), height: -CGFloat(style.shadow)), blur: CGFloat(style.shadow) * 1.5, color: CGColor(gray: 0, alpha: 0.6))
        }
        if style.outline > 0 {
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(CGFloat(style.outline) * 2)
            ctx.setStrokeColor(color(style.outlineColor))
            CTFrameDraw(frame, ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(color(style.color))
        // Re-draw with the fill colour: the attributed string's own colour is ignored by the fill mode of the context.
        let fillStr = NSAttributedString(string: text, attributes: [.font: f, .paragraphStyle: para, .foregroundColor: NSColor(cgColor: color(style.color)) ?? NSColor.white])
        let fillFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(fillStr), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(fillFrame, ctx)
        return ctx.makeImage()
    }

    /// A tight picture of the watermark text, about `widthPixels` wide.
    static func renderWatermarkText(_ text: String, widthPixels: Int) -> CGImage? {
        let probe = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 100, weight: .semibold)])
        let line0 = CTLineCreateWithAttributedString(probe)
        let w100 = CTLineGetTypographicBounds(line0, nil, nil, nil)
        guard w100 > 1 else { return nil }
        let size = max(8, 100 * Double(widthPixels) / w100)
        let f = NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
        let str = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(str)
        var asc: CGFloat = 0, desc: CGFloat = 0
        let tw = CTLineGetTypographicBounds(line, &asc, &desc, nil)
        let pad: CGFloat = 4
        let W = Int(ceil(tw)) + Int(pad) * 2, H = Int(ceil(asc + desc)) + Int(pad) * 2
        guard let ctx = context(W, H) else { return nil }
        ctx.setShadow(offset: CGSize(width: 1, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.5))
        ctx.textPosition = CGPoint(x: pad, y: pad + desc)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.outputNotWritable(url.deletingLastPathComponent()) }
    }

    /// An image watermark ffmpeg can read: PNG / JPEG pass through; SVG and other formats are rasterised to PNG.
    static func watermarkPNG(from file: URL, tempDirectory: URL, name: String) throws -> URL {
        let ext = file.pathExtension.lowercased()
        if ["png", "jpg", "jpeg"].contains(ext), FileManager.default.isReadableFile(atPath: file.path) { return file }
        var cg: CGImage?
        if let src = CGImageSourceCreateWithURL(file as CFURL, nil) { cg = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        if cg == nil, let img = NSImage(contentsOf: file) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: Int(512 * max(0.1, img.size.height / max(1, img.size.width))), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            if let rep, let gctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
                img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                NSGraphicsContext.restoreGraphicsState()
                cg = rep.cgImage
            }
        }
        guard let image = cg else { throw ConversionError.fileUnreadable(file) }
        let url = tempDirectory.appendingPathComponent(name)
        try writePNG(image, to: url)
        return url
    }
}
