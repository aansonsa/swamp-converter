import Foundation
import ImageIO
import UniformTypeIdentifiers

// Which realistic fixture feeds which operation. `file(key:)` makes one input of any format key this Mac can write (nil when it cannot: camera RAW, PPTX ...);
// `cases(for:)` picks the inputs an operation declares it accepts, preferring formats that differ from its target so a wheel run never skips them.

enum ConformanceInputs {
    /// Preference order when an operation accepts several formats: lossless / native first, so conversions are judged against a clean source.
    static let preference = ["png", "jpg", "tiff", "bmp", "gif", "webp", "heic", "ico", "svg", "wav", "flac", "aiff", "m4a", "mp3", "caf", "ogg", "opus",
                             "mp4", "mov", "mkv", "webm", "avi", "pdf", "md", "html", "docx", "odt", "txt", "rtf", "csv", "tsv", "xlsx", "srt", "vtt",
                             "zip", "tar.gz", "tar"]

    @MainActor
    static func file(key: String, fx: ConformanceFixtures, name: String? = nil, variant: Int = 0) async throws -> URL? {
        let stem = name ?? "sample"
        let seed = UInt64(7 + variant)
        func img(_ type: UTType, _ ext: String, w: Int = 640, h: Int = 480) -> URL? {
            try? fx.base.writeImage(fx.photoImage(width: w, height: h), name: "\(stem).\(ext)", type: type)
        }
        switch key {
        case "png": return try fx.photo("\(stem).png", seed: seed)
        case "jpg": return try fx.photoJPEG("\(stem).jpg")
        case "tiff": return img(.tiff, "tiff")
        case "bmp": return img(.bmp, "bmp")
        case "gif":
            guard let dest = CGImageDestinationCreateWithURL(fx.url("\(stem).gif") as CFURL, UTType.gif.identifier as CFString, 3, nil) else { return nil }
            for seed in [1, 2, 3] as [UInt64] { CGImageDestinationAddImage(dest, fx.photoImage(width: 160, height: 120, seed: seed), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary) }
            return CGImageDestinationFinalize(dest) ? fx.url("\(stem).gif") : nil
        case "webp":
            if let cwebp = ExternalProbe.path(.cwebp) {
                let png = try fx.photo("\(stem)-src.png")
                let out = fx.url("\(stem).webp")
                return ExternalProbe.run(cwebp, ["-quiet", "-q", "92", png.path, "-o", out.path], timeout: 30).status == 0 ? out : nil
            }
            return img(.webP, "webp")
        case "heic": return img(.heic, "heic")
        case "ico": return img(.ico, "ico", w: 128, h: 128)
        case "svg": return try fx.base.svg("\(stem).svg", width: 320, height: 240)
        case "wav": return try fx.chirp("\(stem).wav", seed: UInt64(11 + variant))
        case "flac", "aiff", "m4a", "mp3", "caf", "ogg", "opus", "aac", "wma":
            return fx.audioVariant(of: try fx.chirp("\(stem)-src.wav"), ext: key).flatMap { src -> URL? in
                let dst = fx.url("\(stem).\(key)")
                if src == dst { return dst }
                try? FileManager.default.moveItem(at: src, to: dst)
                return dst
            }
        case "mp4", "mov": return try await fx.movingVideo("\(stem).\(key)")
        case "mkv", "webm", "avi", "flv", "mpg", "ts", "3gp", "wmv":
            guard ExternalProbe.has(.ffmpeg) else { return nil }
            let base = try await fx.movingVideo("\(stem)-src.mp4")
            return fx.videoVariant(of: base, ext: key).flatMap { src -> URL? in
                let dst = fx.url("\(stem).\(key)")
                if src != dst { try? FileManager.default.moveItem(at: src, to: dst) }
                return dst
            }
        case "pdf": return try fx.richPDF("\(stem).pdf", pages: 3, seed: UInt64(5 + variant)).url
        case "md": return try fx.markdownDoc("\(stem).md")
        case "html": return try fx.htmlDoc("\(stem).html")
        case "docx": return try fx.docx("\(stem).docx")
        case "odt": return try fx.odt("\(stem).odt")
        case "txt": return try fx.base.text("\(stem).txt", "Swamp report\n\nThis is the introduction. Привет, мир.\nŽluťoučký kůň úpěl ďábelské ódy.\n")
        case "rtf": return try fx.rtfDoc("\(stem).rtf")
        case "csv": return try fx.unicodeCSV("\(stem).csv")
        case "tsv": return try fx.unicodeCSV("\(stem).tsv", delimiter: "\t")
        case "xlsx": return try fx.xlsx("\(stem).xlsx")
        case "srt": return try fx.srtFile("\(stem).srt")
        case "vtt": return try fx.vttFile("\(stem).vtt")
        case "zip", "tar", "tar.gz", "tar.bz2", "tar.xz":
            let proj = try fx.archiveSource("\(stem)-tree")
            let out = "\(stem).\(key)"
            let rel = proj.lastPathComponent
            switch key {
            case "zip": return try fx.base.zip(out, items: [rel])
            case "tar.gz": return try fx.base.tarGz(out, items: [rel])
            case "tar":
                let r = ExternalProbe.run("/usr/bin/bsdtar", ["-cf", fx.url(out).path, rel], currentDirectory: fx.root)
                return r.status == 0 ? fx.url(out) : nil
            case "tar.bz2":
                let r = ExternalProbe.run("/usr/bin/bsdtar", ["-cjf", fx.url(out).path, rel], currentDirectory: fx.root)
                return r.status == 0 ? fx.url(out) : nil
            default:
                let r = ExternalProbe.run("/usr/bin/bsdtar", ["-cJf", fx.url(out).path, rel], currentDirectory: fx.root)
                return r.status == 0 ? fx.url(out) : nil
            }
        default: return nil
        }
    }

    /// The format key a default case for `meta` should use: the most preferred one it accepts that is not its own target.
    static func inputKeys(for meta: OperationMeta) -> [String] {
        guard let accepted = meta.inputs else { return [] }
        let ordered = preference.filter { accepted.contains($0) && $0 != meta.targetFormat }
        let rest = accepted.subtracting(ordered).subtracting([meta.targetFormat ?? ""]).sorted()
        return ordered + rest
    }

    /// The default fixture set of any operation: one input in the best available accepted format (two or three files for merge-style operations);
    /// operations that take any file get a text file, and a folder when they accept folders.
    @MainActor
    static func cases(for meta: OperationMeta, fx: ConformanceFixtures) async throws -> [ConformanceCase] {
        let count = max(1, meta.minItems)
        if meta.inputs == nil {
            var inputs = [try fx.base.text("note.txt", "Swamp note\nПривет, мир\n")]
            if count > 1 { inputs.append(try fx.base.text("second.txt", "Second\n")) }
            var cases = [ConformanceCase(label: "files", inputs: inputs)]
            if meta.acceptsDirectories { cases.append(ConformanceCase(label: "folder", inputs: [try fx.archiveSource("folder")])) }
            return cases
        }
        for key in inputKeys(for: meta) {
            var files: [URL] = []
            for i in 0..<(count > 1 ? max(count, 2) : 1) {
                guard let f = try await file(key: key, fx: fx, name: count > 1 ? "part\(i + 1)" : "sample", variant: i) else { break }
                files.append(f)
            }
            if files.count >= count { return [ConformanceCase(label: key, inputs: files)] }
        }
        return []
    }
}
