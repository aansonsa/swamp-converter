import Foundation

// "Can an independent decoder actually read this?" for every format the app writes. Independent means: not the code that wrote the file. The answer is
// ok / failed / unverified (no decoder on this Mac), and `unverified` is reported, never counted as proof.

enum DecodeVerdict {
    case ok(String)
    case failed(String)
    case unverified(String)
}

enum ConformanceDecode {
    static func check(_ url: URL, sniffed: SniffedFormat) async -> DecodeVerdict {
        switch sniffed.key {
        case "png", "jpg", "gif", "tiff", "bmp", "ico", "icns", "webp", "avif", "heic", "jp2", "jxl", "psd", "exr": return image(url, sniffed)
        case "pdf":
            guard let f = PDFReader.facts(url) else { return .failed("PDFKit cannot open the file") }
            if f.isLocked { return .ok("PDF is locked (password protected), \(f.pageCount) page(s)") }
            return f.pageCount >= 1 ? .ok("PDFKit opens \(f.pageCount) page(s)") : .failed("PDF has no pages")
        case "wav", "aiff", "caf", "flac", "mp3", "m4a", "aac", "ogg", "opus", "oga", "ac3", "amr":
            if let s = AudioFidelity.decode(url), s.frames > 0 { return .ok("\(s.decoder) decoded \(s.frames) frames at \(Int(s.sampleRate)) Hz, \(s.channelCount) ch") }
            return ExternalProbe.has(.ffmpeg) ? .failed("neither AVAudioFile nor ffmpeg can decode the audio") : .unverified("no decoder for \(sniffed.key) without ffmpeg")
        case "mp4", "mov", "3gp":
            let p = await VideoFidelity.playback(of: url, maxVideoFrames: 12)
            if !p.isPlayable { return .failed("AVFoundation says the file is not playable \(p.readError ?? "")") }
            if sniffed.hasVideo && p.videoFrames == 0 { return .failed("AVAssetReader delivered no video frames: \(p.readError ?? "no error")") }
            if let e = p.readError { return .failed("AVAssetReader error: \(e)") }
            return .ok("AVFoundation plays it (\(p.videoFrames) frames read, \(p.audioFrames) audio frames)")
        case "mkv", "webm", "avi", "flv", "mpg", "ts", "asf", "ogv":
            guard ExternalProbe.has(.ffmpeg) else { return .unverified("ffmpeg is needed to decode \(sniffed.key)") }
            let r = VideoFidelity.decodesCleanly(url)
            return r.ok ? .ok("ffmpeg decodes the whole file without errors") : .failed(r.message)
        case "zip", "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub": return archiveOrDocument(url, sniffed)
        case "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "7z", "rar":
            return ExternalProbe.archiveMembers(url) != nil ? .ok("bsdtar lists the members") : .failed("bsdtar cannot read the archive")
        case "gz": return tool("/usr/bin/gzip", ["-t", url.path], "gzip -t")
        case "bz2": return tool("/usr/bin/bzip2", ["-t", url.path], "bzip2 -t")
        case "xz": return ExternalProbe.path(.xz).map { tool($0, ["-t", url.path], "xz -t") } ?? .unverified("xz is not installed")
        case "zst": return ExternalProbe.path(.zstd).map { tool($0, ["-t", url.path], "zstd -t") } ?? .unverified("zstd is not installed")
        case "srt", "vtt", "ass":
            let cues = SubtitleFidelity.read(url) ?? []
            return cues.isEmpty ? .failed("no subtitle cues can be parsed") : .ok("\(cues.count) cue(s) parse")
        case "csv", "tsv":
            return (TableFidelity.readDelimited(url)?.rows.count ?? 0) > 0 ? .ok("table parses") : .failed("no rows can be parsed")
        case "html", "xml", "svg", "md", "txt", "rtf", "json":
            guard let data = try? Data(contentsOf: url) else { return .failed("unreadable") }
            if sniffed.key == "rtf" { return TextCompare.textutilText(url) != nil ? .ok("textutil reads the RTF") : .failed("textutil cannot read the RTF") }
            return String(data: data, encoding: .utf8) != nil || FormatSniffer.decodeText(Array(data.prefix(65536))) != nil ? .ok("decodes as text") : .failed("not valid text")
        case "ole": return .unverified("legacy Office format")
        default: return .unverified("no independent decoder for \(sniffed.key)")
        }
    }

    private static func tool(_ exe: String, _ args: [String], _ label: String) -> DecodeVerdict {
        let r = ExternalProbe.run(exe, args, timeout: 60)
        return r.status == 0 ? .ok("\(label) passes") : .failed("\(label) failed: \(r.error.prefix(200))")
    }

    private static func image(_ url: URL, _ sniffed: SniffedFormat) -> DecodeVerdict {
        if let img = ImageFidelity.decode(url, largestFrame: true), img.width > 0, img.height > 0 { return .ok("ImageIO decodes \(img.width)x\(img.height)") }
        // ImageIO on this macOS may lack a decoder for a newer format: ffmpeg or dwebp can still prove the file is real.
        if sniffed.key == "webp", let dwebp = ExternalProbe.which("dwebp") {
            let r = ExternalProbe.run(dwebp, [url.path, "-o", "-", "-ppm"], timeout: 30)
            return r.status == 0 ? .ok("dwebp decodes the WebP") : .failed("neither ImageIO nor dwebp decodes the WebP")
        }
        if let ffmpeg = ExternalProbe.path(.ffmpeg) {
            let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-frames:v", "1", "-f", "null", "-"], timeout: 60)
            return r.status == 0 && r.error.isEmpty ? .ok("ffmpeg decodes the picture (ImageIO could not)") : .failed("neither ImageIO nor ffmpeg decodes the picture: \(r.error.prefix(160))")
        }
        return .failed("ImageIO cannot decode the picture")
    }

    private static func archiveOrDocument(_ url: URL, _ sniffed: SniffedFormat) -> DecodeVerdict {
        let zip = ExternalProbe.zipIsIntact(url)
        guard zip.ok else { return .failed("unzip -t fails: \(zip.message.prefix(200))") }
        switch sniffed.key {
        case "docx": return DocStructure.readDocx(url) != nil ? .ok("unzip -t passes and word/document.xml parses") : .failed("word/document.xml does not parse")
        case "odt": return DocStructure.readODT(url) != nil ? .ok("unzip -t passes and content.xml parses") : .failed("content.xml does not parse")
        case "xlsx": return TableFidelity.readXLSX(url) != nil ? .ok("unzip -t passes and the workbook parses") : .failed("the workbook does not parse")
        case "ods": return TableFidelity.readODS(url) != nil ? .ok("unzip -t passes and content.xml parses") : .failed("content.xml does not parse")
        case "epub":
            let names = Set((ZipProbe.entries(url) ?? []).map(\.name))
            return names.contains("META-INF/container.xml") && names.contains("mimetype") ? .ok("EPUB container is complete") : .failed("EPUB lacks mimetype or META-INF/container.xml")
        default: return .ok("unzip -t passes")
        }
    }
}
