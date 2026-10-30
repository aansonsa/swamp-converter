import Foundation
import CoreGraphics
import ImageIO
import PDFKit

// Independent read-back checks used by the sizefit self-tests: they never use the code that wrote the file.

enum FitOracle {
    /// `file --mime-type -b`: a sniffer that shares nothing with the writers.
    static func mime(_ url: URL) async throws -> String {
        let out = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/file"), ["--mime-type", "-b", url.path], captureStdout: true)
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ImageIO's own type sniffing (by content, not by extension).
    static func imageType(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// Decodes the first frame with orientation applied to 8-bit RGBA (premultiplied), no larger than `maxPixel` on the long side.
    static func pixels(_ url: URL, maxPixel: Int = 100_000) -> (w: Int, h: Int, data: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        return pixels(img)
    }

    static func pixels(_ img: CGImage) -> (w: Int, h: Int, data: [UInt8])? {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, data) : nil
    }

    /// PSNR (dB) of two same-size RGBA buffers over the colour channels. Identical buffers give 99.
    static func psnr(_ a: (w: Int, h: Int, data: [UInt8]), _ b: (w: Int, h: Int, data: [UInt8])) -> Double {
        guard a.w == b.w, a.h == b.h, a.data.count == b.data.count, !a.data.isEmpty else { return 0 }
        var sum = 0.0
        var i = 0
        while i < a.data.count {
            for c in 0..<3 { let d = Double(a.data[i + c]) - Double(b.data[i + c]); sum += d * d }
            i += 4
        }
        let mse = sum / Double(a.w * a.h * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// PSNR of `output` against `source`, both compared at the SOURCE size (a reduced result is enlarged back), so results of different sizes are comparable
    /// with each other: shrinking the picture costs PSNR just like compressing it harder.
    static func imagePSNR(source: URL, output: URL) -> Double? {
        guard let s = pixels(source), let src = CGImageSourceCreateWithURL(output as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 100_000] as CFDictionary) else { return nil }
        let w = s.w, h = s.h
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? psnr(s, (w, h, data)) : nil
    }

    /// Metadata dictionaries of an image file (GPS, TIFF make).
    static func imageProperties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }

    /// SSIM "All" of `output` against `source` scaled to the same frame size, measured by ffmpeg's ssim filter.
    static func videoSSIM(source: URL, output: URL, width: Int, height: Int) async throws -> Double {
        let ffmpeg = try ToolLocator.shared.require(.ffmpeg)
        let graph = "[0:v]scale=\(width):\(height):flags=bicubic,setsar=1[a];[1:v]scale=\(width):\(height):flags=bicubic,setsar=1[b];[a][b]ssim"
        let found = Locked<Double?>(nil)
        try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", output.path, "-i", source.path, "-lavfi", graph, "-f", "null", "-"], onStderrLine: { line in
            guard let r = line.range(of: "SSIM Y:"), let all = line[r.upperBound...].range(of: "All:") else { return }
            let tail = line[all.upperBound...].prefix { !$0.isWhitespace }
            if let v = Double(tail) { found.withLock { $0 = v } }
        })
        guard let v = found.value else { throw TestFailure(message: "ffmpeg printed no SSIM line", file: #fileID, line: #line) }
        return v
    }

    /// Pages and text of a PDF as PDFKit reads them.
    static func pdfFacts(_ url: URL) -> (pages: Int, text: String, size: CGSize, title: String?, author: String?)? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, let p = doc.page(at: 0) else { return nil }
        let attrs = doc.documentAttributes ?? [:]
        return (doc.pageCount, doc.string ?? "", p.bounds(for: .mediaBox).size, attrs[PDFDocumentAttribute.titleAttribute] as? String, attrs[PDFDocumentAttribute.authorAttribute] as? String)
    }
}
