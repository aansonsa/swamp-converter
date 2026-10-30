import Foundation

// Oracles for the "play everywhere" transcode (Best for Apple / Maximum quality / Universal) and for "compress to N MB".
// The promise is checked on the streams themselves: a remux must copy the elementary stream bit for bit (MD5 of the copied video), a transcode must
// land in the codec, tag, bit depth and colour description the mode promises, and every result must really play in AVFoundation.

extension ConformanceOracles {
    // MARK: Smart transcode

    private static func smartCases(_ fx: ConformanceFixtures, hdr: Bool) async throws -> [ConformanceCase] {
        let clip = try await fx.movingVideo("apple.mp4", ConformanceFixtures.VideoSpec(seconds: 2))
        var cases = [ConformanceCase(label: "H.264+AAC (plays already)", inputs: [clip])]
        if let webm = fx.videoVariant(of: clip, ext: "webm") { cases.append(ConformanceCase(label: "VP9+Opus WebM", inputs: [webm])) }
        if hdr, let ffmpeg = ExternalProbe.path(.ffmpeg), Capabilities.shared.has("ff.enc.libvpx-vp9") {
            let out = fx.url("hdr.webm")
            let r = ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", clip.path, "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p10le", "-crf", "30", "-b:v", "0", "-deadline", "realtime", "-cpu-used", "8",
                                               "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-color_range", "tv", "-c:a", "libopus", "-b:a", "96k", out.path], timeout: 240)
            if r.status == 0 { cases.append(ConformanceCase(label: "10-bit HDR10 VP9", inputs: [out])) }
        }
        return cases
    }

    static let smartBest = ConformanceOracle(
        id: "smart.best", priority: 10, match: { $0.id == "smart.best" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 900,
        cases: { _, fx in try await smartCases(fx, hdr: true) },
        verify: { run in
            let out = try run.sole()
            guard let src = ExternalProbe.ffprobe(run.input, countFrames: true), let sv = src.video.first, let dst = ExternalProbe.ffprobe(out, countFrames: true), let ov = dst.video.first else { throw run.fail("ffprobe failed") }
            let sniffed = try unwrap(FormatSniffer.sniff(out))
            try expect(["mp4", "mov"].contains(sniffed.key), "Best for Apple writes MP4 or MOV, got \(sniffed)")
            try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
            try expect(abs((ov.width ?? 0) - (sv.width ?? 0)) <= 1 && abs((ov.height ?? 0) - (sv.height ?? 0)) <= 1, "the picture size must stay \(sv.width ?? 0)x\(sv.height ?? 0), got \(ov.width ?? 0)x\(ov.height ?? 0)")
            try expect(abs((ov.fps ?? 0) - (sv.fps ?? 0)) <= 0.2, "the frame rate must stay")
            try expect(!src.audio.isEmpty && !dst.audio.isEmpty, "the sound track must be kept")
            if ["h264", "hevc"].contains(sv.codec) {
                // Already Apple-friendly: a lossless stream copy.
                guard let a = VideoFidelity.videoStreamMD5(run.input), let b = VideoFidelity.videoStreamMD5(out) else { throw run.fail("cannot hash the video streams") }
                try expect(a == b, "the source already plays on Apple devices and must be copied bit for bit, but the video stream was changed")
                try expectEqual(dst.audio[0].codec, src.audio[0].codec, "AAC / ALAC audio is copied as it is")
                run.note("remux: video stream identical (MD5), no quality lost")
            } else {
                try expectEqual(ov.codec, "hevc", "a non-Apple codec becomes HEVC")
                try expectEqual(ov.codecTag, "hvc1", "HEVC needs the hvc1 tag to play in QuickTime and Safari")
                try expectEqual(dst.audio[0].codec, "aac", "other audio becomes AAC")
                if let bits = sv.pixFmt, bits.contains("10") { try expect(ov.pixFmt?.contains("10") ?? false, "10-bit video must stay 10-bit, got \(ov.pixFmt ?? "?")") }
                if sv.colorTransfer == "smpte2084" {
                    try expectEqual(ov.colorTransfer, "smpte2084", "HDR10 transfer characteristics must be preserved")
                    try expectEqual(ov.colorPrimaries, "bt2020", "HDR10 primaries must be preserved")
                }
                guard let sim = VideoFidelity.similarity(reference: run.input, test: out) else { throw run.fail("cannot measure similarity") }
                try expect(sim.ssim >= 0.90 && sim.psnr >= 33, "visibly worse than the source: " + sim.summary)
                run.note("\(sv.codec) -> hevc \(ov.pixFmt ?? ""), " + sim.summary)
            }
        },
        proves: "streams that already play on Apple devices are copied bit for bit; the rest becomes HEVC (hvc1) with size, fps, bit depth and HDR tags kept, AAC sound, close to the source, and it plays in AVFoundation")

    static let smartMax = ConformanceOracle(
        id: "smart.max", priority: 10, match: { $0.id == "smart.max" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 600,
        cases: { _, fx in try await smartCases(fx, hdr: false) },
        verify: { run in
            let out = try run.sole()
            guard let src = ExternalProbe.ffprobe(run.input), let dst = ExternalProbe.ffprobe(out), let sv = src.video.first, let ov = dst.video.first else { throw run.fail("ffprobe failed") }
            try expectEqual(ov.codec, sv.codec, "Maximum quality never re-encodes the picture")
            guard let a = VideoFidelity.videoStreamMD5(run.input), let b = VideoFidelity.videoStreamMD5(out) else { throw run.fail("cannot hash the video streams") }
            try expect(a == b, "the video stream was changed; Maximum quality must copy it bit for bit")
            try expectEqual(dst.audio.count, src.audio.count, "every audio track is kept")
            try expectEqual(dst.audio.first?.codec, src.audio.first?.codec, "the sound is copied, not re-encoded")
            try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
            run.note("all streams copied (video MD5 equal)")
        },
        proves: "every stream copied without re-encoding (video bit for bit), all audio tracks kept")

    static let smartUniversal = ConformanceOracle(
        id: "smart.universal", priority: 10, match: { $0.id == "smart.universal" }, requires: ["tool.ffprobe", "tool.ffmpeg"], timeout: 900,
        cases: { _, fx in
            var cases = try await smartCases(fx, hdr: false)
            let big = fx.url("qhd.mp4")
            if let ffmpeg = ExternalProbe.path(.ffmpeg), let clip = cases.first?.inputs.first,
               ExternalProbe.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", clip.path, "-t", "1", "-vf", "scale=2560:1440", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20", "-c:a", "aac", big.path], timeout: 240).status == 0 {
                cases.append(ConformanceCase(label: "2560x1440", inputs: [big]))
            }
            return cases
        },
        verify: { run in
            let out = try run.sole()
            guard let src = ExternalProbe.ffprobe(run.input), let dst = ExternalProbe.ffprobe(out), let sv = src.video.first, let ov = dst.video.first else { throw run.fail("ffprobe failed") }
            let sniffed = try unwrap(FormatSniffer.sniff(out))
            try expectEqual(sniffed.key, "mp4", "Universal is an MP4")
            try expectEqual(ov.codec, "h264", "Universal is H.264")
            try expectEqual(ov.pixFmt, "yuv420p", "8-bit 4:2:0 plays on everything")
            try expect((ov.height ?? 0) <= 1080, "Universal is 1080p at most, got \(ov.height ?? 0)")
            if (sv.height ?? 0) <= 1080 { try expect(abs((ov.height ?? 0) - (sv.height ?? 0)) <= 1, "a picture within 1080p keeps its size") }
            try expectEqual(dst.audio.first?.codec, "aac", "Universal sound is AAC")
            try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.1, "duration changed")
            guard let sim = VideoFidelity.similarity(reference: run.input, test: out) else { throw run.fail("cannot measure similarity") }
            try expect(sim.ssim >= 0.88 && sim.psnr >= 31, "visibly worse than the source: " + sim.summary)
            run.note("\(ov.codec) \(ov.width ?? 0)x\(ov.height ?? 0), " + sim.summary)
        },
        proves: "H.264 8-bit 4:2:0 with AAC in MP4, 1080p at most (larger pictures scaled down, smaller ones untouched), close to the source")

    /// The lowest PSNR over the pages between the source PDF and the result, both rendered by PDFKit at 900 px width; nil when a page cannot be rendered.
    private static func worstPagePSNR(source: URL, result: URL) -> Double? {
        guard let a = PDFReader.facts(source), let b = PDFReader.facts(result), a.pageCount == b.pageCount, a.pageCount > 0 else { return nil }
        var worst = Double.infinity
        for i in 0..<a.pageCount {
            guard let x = ImageFidelity.rasterize(pdf: source, page: i, width: 900), let y = ImageFidelity.rasterize(pdf: result, page: i, width: 900), let p = ImageFidelity.psnr(x, y) else { return nil }
            worst = min(worst, p)
        }
        return worst
    }

    // MARK: Compress to N MB

    static let fitToSize = ConformanceOracle(
        id: "fit.size", priority: 10, match: { $0.id.hasPrefix("fit.") && $0.wheel == .tools }, timeout: 900,
        cases: { meta, fx in
            let inputs = meta.inputs ?? []
            let key = ["png", "wav", "mp4", "pdf"].first { inputs.contains($0) } ?? "png"
            let source: URL?
            switch key {
            case "pdf": source = try fx.richPDF("photos.pdf", pages: 3, withImage: true).url
            default: source = try await ConformanceInputs.file(key: key, fx: fx, name: "big")
            }
            guard let src = source else { return [] }
            let bytes = TestFile.size(src)
            let fraction = key == "wav" ? 0.12 : (key == "mp4" ? 0.35 : (key == "pdf" ? 0.4 : 0.3))
            let megabytes = (Double(bytes) * fraction / 10_000).rounded() / 100   // two decimals
            var c = ConformanceCase(label: "\(key) to \(megabytes) MB", inputs: [src])
            c.extra = ["fit.target": "custom", "fit.customMB": .double(megabytes)]
            return [c]
        },
        verify: { run in
            let out = try run.sole()
            let target = run.options.double("fit.customMB", 0) * 1_000_000
            let size = Double(TestFile.size(out))
            try expect(target > 0, "the custom size did not reach the operation")
            try expect(size <= target, String(format: "the result is %.0f bytes, over the target of %.0f bytes", size, target))
            let key = Formats.key(of: run.input)
            if size < target * 0.85 {
                // Far below the limit is only honest when there was nothing left to spend it on: a PDF whose pages already match the source nearly pixel for pixel
                // (the re-encoding step of the method has a top quality and a coarse jump above it). For every other kind it means quality was thrown away.
                let fidelity = key == "pdf" ? worstPagePSNR(source: run.input, result: out) : nil
                try expect((fidelity ?? 0) >= ConformanceThresholds.fitPdfNearLosslessPSNR, String(format: "the result is %.0f bytes, far below the target of %.0f bytes: quality was thrown away for nothing (%.0f%% of the target%@)", size, target, size / target * 100, fidelity.map { String(format: "; the pages are only %.1f dB from the source", $0) } ?? ""))
                run.note(String(format: "%.0f%% of the target, but every page is %.1f dB from the source: nothing left to spend the rest on", size / target * 100, fidelity ?? 0))
            }
            if Formats.imageInputs.contains(key) || Formats.rawInputs.contains(key) {
                guard let c = ImageFidelity.compare(source: run.input, output: out, allowResize: true) else { throw run.fail("cannot compare pictures") }
                try expect(c.psnr >= 20, "the picture is destroyed: " + c.summary)
                run.note(String(format: "%.0f%% of the target, ", size / target * 100) + c.summary)
            } else if Formats.audioInputs.contains(key) {
                guard let a = AudioFidelity.decode(run.input), var b = AudioFidelity.decode(out) else { throw run.fail("cannot decode the sound") }
                try expect(abs(a.duration - b.duration) <= 0.03, String(format: "duration changed: %.3f s to %.3f s", a.duration, b.duration))
                var ref = a
                if abs(b.sampleRate - a.sampleRate) > 0.5, let r = AudioFidelity.resampled(a, to: b.sampleRate) { ref = r }
                if ref.channelCount != b.channelCount { run.note("channels \(a.channelCount)->\(b.channelCount)") } else {
                    let n = min(ref.frames, b.frames); ref.channels = ref.channels.map { Array($0.prefix(n)) }; b.channels = b.channels.map { Array($0.prefix(n)) }
                    if let m = AudioFidelity.match(ref: ref, test: b) { try expect(m.snr >= 8, "the sound is destroyed: " + m.summary); run.note(String(format: "%.0f%% of the target, ", size / target * 100) + m.summary) }
                }
            } else if key == "pdf" {
                guard let a = PDFReader.facts(run.input), let b = PDFReader.facts(out) else { throw run.fail("cannot read the PDFs") }
                try expectEqual(b.pageCount, a.pageCount, "page count")
                try expect(TextCompare.wordRecall(expected: a.allText, actual: b.allText) >= 0.9, "text lost while shrinking the PDF")
                run.note(String(format: "%.0f%% of the target, %d pages, text kept", size / target * 100, b.pageCount))
            } else if Formats.videoInputs.contains(key) {
                guard let src = ExternalProbe.ffprobe(run.input), let dst = ExternalProbe.ffprobe(out), let sv = src.video.first, dst.video.first != nil else { throw run.fail("ffprobe failed") }
                try expect(abs((dst.duration ?? 0) - (src.duration ?? 0)) <= 0.12, "duration changed")
                guard let sim = VideoFidelity.similarity(reference: run.input, test: out, size: (sv.width ?? 640, sv.height ?? 360)) else { throw run.fail("cannot measure similarity") }
                try expect(sim.ssim >= 0.85, "the video is destroyed: " + sim.summary)
                run.note(String(format: "%.0f%% of the target, ", size / target * 100) + sim.summary)
            }
        },
        proves: "never over the requested size and not far below it (85 to 100%), content intact: picture PSNR, sound SNR and length, PDF pages and text, video SSIM and length")
}
