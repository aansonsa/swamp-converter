import Foundation

/// "conformance.smart": every operation of the catalogue is run through its real `execute` path and judged by an independent oracle (magic bytes,
/// ffprobe `format_name`, `file --mime-type`, stream properties, SSIM / PSNR, md5 of copied streams). The cases are generated from
/// `SmartCatalog.operations()`: a new operation without a case below FAILS the suite. A second test proves that every schema field's `.oracle(...)`
/// is named by a real test in this module.
enum SmartConformanceTests {
    private static let need = ["tool.ffmpeg", "ff.enc.libvpx-vp9", "ff.enc.libopus", "ff.enc.hevc_videotoolbox"]

    /// What an output must be, per container: leading bytes, ffprobe format_name fragment, accepted `file` mime types.
    private static func sniff(_ url: URL) async -> (magic: String, format: String, mime: String) {
        let head = TestFile.magic(url, 12)
        let magic: String
        if head.count >= 8, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" { magic = "iso-bmff:" + String(decoding: head[8..<12], as: UTF8.self).trimmingCharacters(in: .whitespaces) }
        else if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { magic = "ebml" }
        else { magic = "unknown" }
        return (magic, await SK.formatName(url), SK.mimeType(url))
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("conformance.smart", "every operation of the catalogue has a conformance case and produces a real, independently verified file", requires: need) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try await SK.requireMediaStack(fx)
            let vp9 = try await SK.vp9(fx, "source.webm", seconds: 2)
            let big = try await SK.clip(fx, "big.mp4", size: "2560x1440", fps: 12, seconds: 1, video: ["-c:v", "mpeg4", "-q:v", "6"], audio: ["-c:a", "aac"])
            let h264 = try await SK.clip(fx, "h264.mp4", seconds: 2)
            struct Case { var source: URL; var codec: String; var ext: String; var magic: String; var format: String; var mimes: [String]; var passthrough: Bool; var width: Int?; var lossless: Bool }
            let cases: [String: [Case]] = [
                "smart.best": [Case(source: vp9, codec: "hevc", ext: "mp4", magic: "iso-bmff", format: "mp4", mimes: ["video/mp4"], passthrough: false, width: 640, lossless: false),
                               Case(source: h264, codec: "h264", ext: "mp4", magic: "iso-bmff", format: "mp4", mimes: ["video/mp4"], passthrough: true, width: 320, lossless: true)],
                "smart.max": [Case(source: vp9, codec: "vp9", ext: "webm", magic: "ebml", format: "webm", mimes: ["video/webm", "video/x-matroska"], passthrough: true, width: 640, lossless: true)],
                "smart.universal": [Case(source: big, codec: "h264", ext: "mp4", magic: "iso-bmff", format: "mp4", mimes: ["video/mp4"], passthrough: false, width: 1920, lossless: false)]
            ]
            for op in SmartCatalog.operations() {
                let list = try unwrap(cases[op.meta.id], "\(op.meta.id) has no conformance case: add an oracle for every operation")
                for (n, c) in list.enumerated() {
                    let label = "\(op.meta.id)#\(n)"
                    let item = FileItem(url: c.source)
                    let ctx = OperationContext.testing(op, items: [item])
                    let result = try await op.execute(items: [item], ctx: ctx)
                    try expect(result.failures.isEmpty, "\(label): \(result.failures)")
                    let out = try unwrap(result.outputs.first, "\(label): no output")
                    try expectEqual(result.outputs.count, 1, label)
                    // 1. What is it really? Three methods that do not share code with the writer.
                    let s = await sniff(out)
                    try expectEqual(out.pathExtension, c.ext, "\(label): extension")
                    try expect(s.magic.hasPrefix(c.magic), "\(label): magic bytes say \(s.magic)")
                    try expect(s.format.contains(c.format), "\(label): ffprobe format_name is \(s.format)")
                    try expect(c.mimes.contains(s.mime), "\(label): file(1) says \(s.mime)")
                    // 2. Streams and fidelity.
                    let v = try unwrap(await SK.streams(out, "video").first), a = await SK.streams(out, "audio")
                    try expectEqual(SK.str(v, "codec_name"), c.codec, label)
                    if let w = c.width { try expectEqual(SK.int(v, "width"), w, "\(label): width") }
                    try expect(!a.isEmpty, "\(label): audio must be present")
                    let durOut = await SK.duration(out), durIn = await SK.duration(c.source)
                    try expectClose(durOut, durIn, tolerance: 0.1, "\(label): duration")
                    if c.lossless {
                        try await SK.expectSameStream(out, c.source, audio: false, "\(label): a declared remux copies the picture bit for bit")
                    } else {
                        // Compare against the source scaled to the output size so SSIM measures the codec, not the resize.
                        let ref = fx.url("ref-\(n)-\(op.meta.id).mkv")
                        let size = (SK.int(v, "width"), SK.int(v, "height"))
                        try await SK.ffmpeg(["-i", c.source.path, "-vf", "scale=\(size.0):\(size.1):flags=bicubic", "-c:v", "ffv1", "-an", ref.path])
                        let sim = try await SK.similarity(out, ref, in: fx.root)
                        try expect(sim.ssim >= SmartQuality.minimumSSIM && sim.psnr >= 35, "\(label): SSIM \(sim.ssim), PSNR \(sim.psnr) dB")
                        let framesIn = await SK.packetCount(c.source), framesOut = await SK.packetCount(out)
                        try expectEqual(framesOut, framesIn, "\(label): frame count")
                    }
                    // 3. Never the input under another name unless it is a declared remux.
                    let same = FileManager.default.contentsEqual(atPath: out.path, andPath: c.source.path)
                    try expect(!same || c.passthrough, "\(label): the output is byte-identical to the input but the case is not declared a passthrough")
                    try expect(out.path != c.source.path, "\(label): the source must not be overwritten")
                }
            }
        }

        t.register("conformance.smart", "Studio and wheel resolve to the same options when the values are the same", requires: []) {
            for op in SmartCatalog.operations() {
                let item = FileItem(url: URL(fileURLWithPath: "/tmp/a.webm"))
                let quick = OperationContext.testing(op, items: [item], mode: .quick)
                let studio = OperationContext.testing(op, items: [item], extra: op.quickOverrides(settings: SettingsData()), mode: .studio)
                try expectEqual(SmartOptions(options: quick.options), SmartOptions(options: studio.options), op.meta.id)
                try expectEqual(quick.options, studio.options, "\(op.meta.id): the same option values")
            }
        }

        t.register("conformance.smart", "every schema field's oracle id is proven by a named test of this module", requires: []) {
            let names = SelfTestRegistry.shared.cases.filter { $0.suite == "smart" }.map(\.name).joined(separator: "\n")
            for f in SmartSchemas.transcode(items: []).allFields {
                try expect(names.contains("(oracle \(f.oracle))"), "no test is named '(oracle \(f.oracle))' for \(f.key)")
            }
        }
    }
}
