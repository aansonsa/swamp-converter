import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Conformance oracles of this module (Core generates one `conformance.*` test per registered operation and asks the oracle that claims it to judge the run).
// Every comparison reads the result with something other than the code that wrote it: ImageIO / PDFKit / ffprobe / AVFoundation, a packet-level MD5, the
// recogniser's own words against the sentence the system voice was asked to say.

enum IntelligenceConformance {
    static func register() {
        let r = ConformanceRegistry.shared
        r.add(scrubOracle); r.add(cutoutOracle); r.add(transcribeOracle)
    }

    // MARK: Share-safe scrub

    static let scrubOracle = ConformanceOracle(
        id: "intelligence.scrub", priority: 100, match: { $0.id.hasPrefix("scrub.") },
        cases: { meta, fx in
            switch meta.id {
            case ScrubSchemas.imageID:
                return [ConformanceCase(label: "jpg-tags", inputs: [try IntelTest.richJPEG(fx.base)]),
                        ConformanceCase(label: "jpg-rotated", inputs: [try fx.photoJPEG("turned.jpg", orientation: 6, gps: true)])]
            case ScrubSchemas.pdfID:
                return [ConformanceCase(label: "pdf-info-xmp", inputs: [try IntelligenceScrubTests.makePDF(fx.base, name: "report.pdf", pages: 3)])]
            case ScrubSchemas.videoID:
                if ToolLocator.shared.has(.ffmpeg) && ToolLocator.shared.has(.ffprobe) { return [ConformanceCase(label: "mp4-tags", inputs: [try IntelligenceScrubMediaTests.makeClip(fx.base)])] }
                return [ConformanceCase(label: "mov-tags", inputs: [try await IntelligenceScrubMediaTests.makeAVMovie(fx.base)])]
            default:
                guard ToolLocator.shared.has(.ffmpeg) else { return [] }
                let src = fx.url("voice.m4a")
                _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=330:duration=2", "-c:a", "aac", "-metadata", "title=Song",
                                              "-metadata", "artist=Andris", "-metadata", "location=+50.0800+014.4200/", src.path])
                return TestFile.exists(src) ? [ConformanceCase(label: "m4a-tags", inputs: [src])] : []
            }
        },
        verify: { run in
            let out = try run.sole()
            let note = try unwrap(run.result.note, "the finished job must say what was removed").en
            try expect(note.hasPrefix("Removed:"), note)
            try expectEqual(Formats.key(of: out), Formats.key(of: run.input), "a scrubbed copy keeps its format")
            switch run.meta.id {
            case ScrubSchemas.imageID:
                let left = ImageScrub.inspect(out).removed
                try expect(!left.contains(.gps) && !left.contains(.cameraMake) && !left.contains(.cameraModel), "personal tags left: \(left)")
                // The reference is the source as a viewer shows it (orientation applied); the copy must look the same.
                let src = try unwrap(CGImageSourceCreateWithURL(run.input as CFURL, nil))
                let size = try unwrap(TestImage.size(of: out))
                let ref = try unwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                                  kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)] as CFDictionary))
                let refURL = try run.fx.base.writeImage(ref, name: "reference-\(run.testCase.label).png", type: .png)
                let psnr = try unwrap(IntelTest.psnr(refURL, out), "sizes differ: \(size) vs \(ref.width)x\(ref.height)")
                try expect(psnr > 38, String(format: "pixels changed, PSNR %.1f dB", psnr))
                try expectEqual(TestImage.info(of: out)?.orientation ?? 1, 1, "orientation must be baked into the pixels")
                run.note(String(format: "PSNR %.1f dB, removed: %@", psnr, note))
            case ScrubSchemas.pdfID:
                let a = try unwrap(PDFDocument(url: run.input)), b = try unwrap(PDFDocument(url: out))
                try expectEqual(b.pageCount, a.pageCount, "page count")
                try expectEqual(b.string, a.string, "extracted text")
                try expect(!PdfScrub.hasXMP(out), "XMP still present")
                let producer = (b.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String) ?? ""
                try expect(producer.trimmingCharacters(in: .whitespaces).isEmpty, "producer still present: \(producer)")
            case ScrubSchemas.videoID:
                let a = await MediaScrub.inspect(run.input, tools: .shared).removed, b = await MediaScrub.inspect(out, tools: .shared).removed
                try expect(a.contains(.gps) || a.contains(.cameraMake), "the fixture should carry personal tags: \(a)")
                try expect(!b.contains(.gps) && !b.contains(.cameraMake) && !b.contains(.cameraModel), "personal tags left: \(b)")
                if let before = IntelTest.streamHash(run.input, stream: "0:v:0") {
                    try expectEqual(IntelTest.streamHash(out, stream: "0:v:0"), before, "the picture must be copied, not re-encoded")
                    run.note("video packets identical")
                } else {
                    let frames = try await IntelligenceScrubMediaTests.frameCount(out), original = try await IntelligenceScrubMediaTests.frameCount(run.input)
                    try expectEqual(frames, original, "frame count")
                }
            default:
                let tags = try unwrap(IntelTest.probeTags(out))
                let all = tags.format.merging(tags.streams.first ?? [:]) { a, _ in a }
                try expect(!all.keys.contains { $0.hasPrefix("location") }, "location still present: \(all)")
                try expectEqual(all["title"], "Song", "title is not part of the quick recipe")
                try expectEqual(IntelTest.streamHash(out, stream: "0:a:0"), IntelTest.streamHash(run.input, stream: "0:a:0"), "the sound must be copied, not re-encoded")
            }
        },
        proves: "the copy has no location / camera tags (read back with ImageIO, PDFKit, ffprobe, AVFoundation), looks and sounds identical (PSNR, text, packet MD5) and the note names what went")

    // MARK: Background removal

    static let cutoutOracle = ConformanceOracle(
        id: "intelligence.cutout", priority: 100, match: { $0.id == CutoutSchemas.removeBackgroundID }, requires: ["native.vision.foreground"],
        cases: { _, fx in
            let png = try fx.base.writeImage(IntelligenceVisionTests.subjectImage(), name: "subject.png", type: .png)
            let jpg = try fx.base.writeImage(IntelligenceVisionTests.subjectImage(), name: "subject.jpg", type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
            return [ConformanceCase(label: "png", inputs: [png]), ConformanceCase(label: "jpg", inputs: [jpg])]
        },
        verify: { run in
            let out = try run.sole()
            try expectEqual(TestFile.magic(out, 4), [0x89, 0x50, 0x4E, 0x47], "a PNG with transparency")
            let info = try unwrap(TestImage.info(of: out))
            try expect(info.hasAlpha, "no alpha channel")
            let a = try IntelligenceVisionTests.readAlpha(out), source = try IntelligenceVisionTests.readAlpha(run.input)
            try expectEqual(a.width, source.width); try expectEqual(a.height, source.height)
            for (x, y) in [(5, 5), (794, 5), (5, 594), (794, 594)] { try expect(a.a(x, y) < 10, "corner (\(x),\(y)) should be transparent, alpha \(a.a(x, y))") }
            for (x, y) in [(400, 320), (360, 270), (440, 370)] { try expect(a.a(x, y) > 245, "subject (\(x),\(y)) should be opaque, alpha \(a.a(x, y))") }
            let box = a.bounds, expected = IntelligenceVisionTests.subject
            try expect(abs(box.minX - expected.minX) < 14 && abs(box.maxX - expected.maxX) < 14 && abs(box.maxY - expected.maxY) < 14, "subject bounds \(box) vs \(expected)")
            // Kept pixels are the source's pixels (a JPEG source is compared with its own decode).
            var worst = 0
            for (x, y) in [(400, 320), (360, 270), (440, 370), (380, 250), (420, 380)] where a.a(x, y) == 255 {
                let p = a.rgb(x, y), q = source.rgb(x, y)
                worst = max(worst, abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2))
            }
            try expect(worst <= 2, "kept pixels changed by \(worst)")
            run.note("opaque \(Int(a.opaqueFraction * 100))%, bounds \(Int(box.width))x\(Int(box.height))")
        },
        proves: "a real PNG with alpha: transparent in the corners, opaque inside the subject, the subject's bounds where it was drawn, kept pixels equal to the source")

    // MARK: Transcription

    static let phrase = "Hello. This is a test of speech recognition on this device. The weather is nice today."

    static let transcribeOracle = ConformanceOracle(
        id: "intelligence.transcribe", priority: 100, match: { $0.id == SpeechSchemas.transcribeID }, requires: ["native.speech.available"], timeout: 240,
        cases: { _, fx in
            guard await SpeechEngine.availability(for: "en-US") == .available else { return [] }
            let say = URL(fileURLWithPath: "/usr/bin/say")
            guard FileManager.default.fileExists(atPath: say.path) else { return [] }
            let aiff = fx.url("speech.aiff")
            _ = SyncProcess.run(say, ["-v", "Samantha", "-o", aiff.path, phrase], timeout: 60)
            guard TestFile.exists(aiff) else { return [] }
            // The quick run copies the text to the clipboard; the oracle catches it instead of touching the person's clipboard.
            captured.value = []
            savedSink.value = TranscribeOperation.clipboardSink
            TranscribeOperation.clipboardSink = { text in captured.withLock { $0.append(text) } }
            let english: OptionValues = [SpeechKeys.language: "en-US"]
            var cases = [ConformanceCase(label: "aiff", inputs: [aiff], extra: english)]
            if ToolLocator.shared.has(.ffmpeg) {
                let clip = try await fx.base.video("clip.mp4", seconds: 1)
                let mp4 = fx.url("talk.mp4")
                _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", clip.path, "-i", aiff.path, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", mp4.path])
                if TestFile.exists(mp4) { cases.append(ConformanceCase(label: "mp4-all-files", inputs: [mp4], extra: [SpeechKeys.language: "en-US", SpeechKeys.format: .string(IntelligenceSpeechTests.subtitleKitIsReal ? "txt,srt,vtt" : "txt")], mode: .studio)) }
            }
            return cases
        },
        verify: { run in
            defer { if run.testCase.label == "aiff", let sink = savedSink.value { TranscribeOperation.clipboardSink = sink } }
            let txt = try unwrap(run.outputs(withExtension: "txt").first, "no TXT written")
            try expect(txt.lastPathComponent.contains("(transcript)") || txt.lastPathComponent.contains("(расшифровка)"), txt.lastPathComponent)
            let text = try String(contentsOf: txt, encoding: .utf8).lowercased()
            let expected = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let hits = expected.filter { text.contains($0) }.count
            try expect(Double(hits) / Double(expected.count) >= 0.7, "recognised \(hits) of \(expected.count) words: \(text)")
            if run.testCase.label == "aiff" {
                try expectEqual(captured.value.first?.lowercased(), text, "a single quick transcription is also on the clipboard")
            } else if IntelligenceSpeechTests.subtitleKitIsReal {
                let srt = try unwrap(run.outputs(withExtension: "srt").first)
                let cues = try SubtitleKit.parse(try String(contentsOf: srt, encoding: .utf8))
                try expect(!cues.isEmpty && cues.allSatisfy { $0.end > $0.start && $0.start >= 0 }, "cues")
                try expect(try String(contentsOf: try unwrap(run.outputs(withExtension: "vtt").first), encoding: .utf8).hasPrefix("WEBVTT"))
            }
            run.note("\(hits)/\(expected.count) words")
        },
        proves: "speech made by the system voice comes back as text with at least 70% of the words, on the clipboard for a quick run, as readable SRT / VTT cues when asked")

    private static let captured = Locked<[String]>([])
    private static let savedSink = Locked<(@Sendable (String) async -> Void)?>(nil)
}
