import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Generated pictures and files for the window's snapshots: a photographic-looking image (sky, hills, texture, a line of text), a worse copy of it for the "after" half, a video frame
// and filmstrip, a waveform, and small real PDF / CSV / SRT / ZIP files. Nothing here is used by the app itself.

@MainActor
final class StudioSnapshotAssets {
    static let shared = StudioSnapshotAssets()

    private let fx = TestFixtures(label: "studio-snap")

    // MARK: Pictures

    /// A synthetic "photo": vertical sky gradient, a sun, two hill silhouettes, grain and a line of text, so lossy compression has something to bite.
    static func photo(width: Int, height: Int, seed: UInt64 = 7, shift: Double = 0) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.98, green: 0.72, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.35, green: 0.55, blue: 0.82, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * (0.62 + shift * 0.1), y: h * 0.55, width: h * 0.22, height: h * 0.22))
        func hill(_ base: CGFloat, _ amp: CGFloat, _ phase: CGFloat, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.beginPath(); ctx.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= w { ctx.addLine(to: CGPoint(x: x, y: base + amp * sin(x / w * 6.0 + phase) + amp * 0.4 * sin(x / w * 17.0 + phase * 2))); x += 4 }
            ctx.addLine(to: CGPoint(x: w, y: 0)); ctx.closePath(); ctx.fillPath()
        }
        hill(h * 0.38, h * 0.08, CGFloat(0.5 + shift), CGColor(srgbRed: 0.24, green: 0.36, blue: 0.30, alpha: 1))
        hill(h * 0.22, h * 0.06, CGFloat(2.1 + shift), CGColor(srgbRed: 0.12, green: 0.20, blue: 0.18, alpha: 1))
        var rng = SplitMix(seed: seed)
        for _ in 0..<(width * height / 40) {
            let v = rng.next()
            let x = CGFloat(v % UInt64(width)), y = CGFloat((v >> 20) % UInt64(height))
            ctx.setFillColor(CGColor(gray: (v >> 40) & 1 == 0 ? 1 : 0, alpha: 0.05))
            ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        let font = CTFontCreateUIFontForLanguage(.system, h * 0.045, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SWAMP LAKE  06:42", attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 0.9)]))
        ctx.textPosition = CGPoint(x: w * 0.05, y: h * 0.05)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    /// The same picture after a heavy lossy round trip (what a too-low quality does).
    static func degraded(_ image: CGImage, quality: Double = 0.1, scale: Double = 1) -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(data, nil), let out = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return image }
        return out
    }

    lazy var photoBefore: CGImage = Self.photo(width: 1600, height: 1000)
    lazy var photoAfter: CGImage = Self.degraded(photoBefore, quality: 0.08)
    lazy var videoFrame: CGImage = Self.photo(width: 1280, height: 720, seed: 11, shift: 0.4)
    lazy var videoFrameAfter: CGImage = Self.degraded(videoFrame, quality: 0.2)
    lazy var verticalFrame: CGImage = Self.photo(width: 720, height: 1280, seed: 13, shift: 0.2)
    lazy var filmstrip: [CGImage] = (0..<12).map { Self.photo(width: 160, height: 90, seed: 11, shift: 0.05 * Double($0)) }

    /// A believable speech-like envelope: bursts and pauses.
    lazy var waveform: [Float] = {
        var rng = SplitMix(seed: 5)
        return (0..<AudioOverviewLoader.buckets).map { i in
            let t = Double(i) / Double(AudioOverviewLoader.buckets)
            let burst = 0.5 + 0.5 * sin(t * 38) * sin(t * 7.3 + 1)
            let jitter = Double(rng.next() % 1000) / 1000
            return Float(min(1, max(0.03, burst * (0.35 + 0.55 * jitter))))
        }
    }()

    // MARK: Files

    lazy var photoURL: URL = { (try? fx.writeImage(photoBefore, name: "Lake.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])) ?? fx.url("Lake.jpg") }()
    lazy var wavURL: URL = (try? fx.wav("Interview.wav", seconds: 2, frequency: 220)) ?? fx.url("Interview.wav")
    lazy var pdfURL: URL = {
        (try? fx.pdf("Report.pdf", pages: 8, text: { "Section \($0 + 1): swamp survey, Привет, мир. Lorem ipsum dolor sit amet." })) ?? fx.url("Report.pdf")
    }()
    lazy var srtURL: URL = {
        let lines = ["We found the old boardwalk.", "Это было в конце лета.", "The water was perfectly still.", "Никто не говорил.", "Then the heron lifted off.", "Ainava bija pilnīgi mierīga."]
        let cues = (0..<40).map { TestFixtures.Cue(start: Double($0) * 3.2, end: Double($0) * 3.2 + 2.6, text: lines[$0 % lines.count]) }
        return (try? fx.srt("Film.srt", cues: cues)) ?? fx.url("Film.srt")
    }()
    lazy var csvURL: URL = {
        var rows: [[String]] = [["Участок", "Район", "Площадь, га", "Дата", "Примечание"]]
        let names = ["Берег", "Лес", "Болото", "Поле", "Озеро", "Дюны"]
        for i in 1...40 { rows.append([names[i % names.count] + " \(i)", "Район \(i % 5 + 1)", String(format: "%.1f", Double(i) * 1.7).replacingOccurrences(of: ".", with: ","), "2026-0\(i % 9 + 1)-1\(i % 9)", i % 7 == 0 ? "проверить" : ""]) }
        return (try? fx.csv("Участки.csv", rows: rows, delimiter: ";")) ?? fx.url("Участки.csv")
    }()
    lazy var zipURL: URL = {
        _ = try? fx.folderTree("Pack", files: ["readme.txt": "Hello", "photos/2026/a.jpg": String(repeating: "x", count: 4000), "photos/2026/b.jpg": String(repeating: "y", count: 9000),
                                                "docs/report.pdf": String(repeating: "z", count: 20000), "docs/notes/todo.md": "- one\n- two"])
        return (try? fx.zip("Pack.zip", items: ["Pack"])) ?? fx.url("Pack.zip")
    }()
    /// A tar whose members could escape the target folder.
    lazy var unsafeTarURL: URL = {
        _ = try? fx.folderTree("sub", files: ["a.txt": "A"])
        _ = try? Data("evil".utf8).write(to: fx.url("evil.txt"))
        let out = fx.url("Unsafe.tar")
        // ExternalProbe waits by sleeping: `Process.waitUntilExit()` spins the run loop, and this runs while SwiftUI is building the window (the archive scene), where a re-entrant
        // update aborts the process with "AttributeGraph: cycle detected".
        _ = ExternalProbe.run("/usr/bin/tar", ["-cPf", out.path, "-C", fx.url("sub").path, "../evil.txt", "a.txt"], timeout: 30, environment: ["PATH": "/usr/bin:/bin"])
        return out
    }()

    func cleanup() { fx.cleanup() }
}
