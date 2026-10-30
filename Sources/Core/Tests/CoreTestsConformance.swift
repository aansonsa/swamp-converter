import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The conformance harness must catch the cheats it exists for. Each fake operation below is a deliberately bad (or honest) converter; the generated
// conformance test of the real registry runs on it exactly as it runs on engine operations.

enum CoreTestsConformance {
    /// A configurable fake: converts PNG / TIFF / JPEG to JPEG (or pretends to).
    final class FakeImageOp: PerFileOperation, @unchecked Sendable {
        enum Mode { case honest, renamed, blank, mirrored, truncated, ignoresQuality, copiesBytes, editsInput, leavesPartial }
        let mode: Mode
        let ext: String
        let sliderSchema: Bool

        init(id: String, mode: Mode, target: String? = "jpg", passthrough: PassthroughKind = .none, slider: Bool = false) {
            self.mode = mode
            self.ext = target ?? "png"
            self.sliderSchema = slider
            let meta: OperationMeta = target != nil
                ? .convert(id, .image, to: target!, symbol: "photo", schema: "zz.fake", inputs: ["png", "tiff", "jpg"], passthrough: passthrough)
                : .make(id, .tools, .image, L10n("Copy", "Копия"), symbol: "doc.on.doc", schema: "zz.fake", inputs: ["png"], suffix: L10n("copy", "копия"), passthrough: passthrough)
            super.init(meta: meta)
        }

        override func optionSchema(for items: [FileItem]) -> OptionSchema {
            guard sliderSchema else { return super.optionSchema(for: items) }
            return OptionSchema(id: "zz.fake", title: L10n("Fake", "Подделка"), pages: [
                .make("main", symbol: "photo", L10n("Main", "Основное"), [.make("g", [.slider("fake.quality", L10n("Quality", "Качество"), min: 10, max: 100, def: 90).oracle("size")])])])
        }

        private func upright(_ url: URL) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary)
        }

        private func flattened(_ img: CGImage, mirrored: Bool = false, blank: Bool = false) -> CGImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
            if !blank {
                if mirrored { ctx.translateBy(x: CGFloat(img.width), y: 0); ctx.scaleBy(x: -1, y: 1) }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            return ctx.makeImage()!
        }

        private func writeJPEG(_ img: CGImage, to url: URL, quality: Double) throws {
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError.message(L10n("encode failed", "ошибка кодирования")) }
        }

        override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
            let quality = mode == .ignoresQuality ? 0.9 : ctx.options.double("fake.quality", 90) / 100
            if mode == .editsInput { try Data([0]).append(to: item.url) }
            if mode == .leavesPartial { try Data("x".utf8).write(to: item.parent.appendingPathComponent(".leftover.deadbeef.part.\(ext)")) }
            let out = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: ext) { tmp in
                switch mode {
                case .renamed, .copiesBytes: try? FileManager.default.removeItem(at: tmp); try FileManager.default.copyItem(at: item.url, to: tmp)
                case .blank: try writeJPEG(flattened(upright(item.url)!, blank: true), to: tmp, quality: quality)
                case .mirrored: try writeJPEG(flattened(upright(item.url)!, mirrored: true), to: tmp, quality: quality)
                case .truncated:
                    try writeJPEG(flattened(upright(item.url)!), to: tmp, quality: quality)
                    let d = try Data(contentsOf: tmp)
                    try d.prefix(d.count * 2 / 5).write(to: tmp)
                default: try writeJPEG(flattened(upright(item.url)!), to: tmp, quality: quality)
                }
            }
            return [out]
        }
    }

    @MainActor
    static func withOperation<T>(_ op: Operation, _ body: () async throws -> T) async throws -> T {
        OperationRegistry.shared.register(op)
        defer { OperationRegistry.shared.unregister(id: op.meta.id) }
        return try await body()
    }

    @MainActor
    static func failure(of op: Operation, registry: ConformanceRegistry = .shared) async throws -> String? {
        try await withOperation(op) {
            do { try await ConformanceRunner.test(operationID: op.meta.id, registry: registry); return nil }
            catch let f as TestFailure { return f.message }
        }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("conformance.calibration", "the oracle floors sit below what real reference encoders reach on the fixtures (images and audio)", timeout: 180) {
            let fx = ConformanceFixtures(label: "calib")
            defer { fx.cleanup() }
            let png = try fx.photo("p.png")
            let src = try unwrap(ImageFidelity.decode(png))
            let dir = try fx.folder("ref")
            func psnr(_ u: URL?) -> Double { u.flatMap { ImageFidelity.decode($0) }.flatMap { ImageFidelity.psnr(src, $0) } ?? 0 }
            let jpg = psnr(ReferenceParity.sipsJPEG(png, quality: 90, into: dir))
            out("      sips JPEG q90: \(String(format: "%.1f", jpg)) dB")
            try expect(jpg >= ConformanceOracles.imageFloors["jpg"]!.0 + 1.5, "the JPEG floor must sit below the reference \(jpg)")
            if ExternalProbe.has(.cwebp) {
                let w = psnr(ReferenceParity.cwebp(png, quality: 90, into: dir))
                out("      cwebp q90: \(String(format: "%.1f", w)) dB")
                try expect(w >= ConformanceOracles.imageFloors["webp"]!.0 + 1.5, "the WebP floor must sit below the reference \(w)")
            }
            if ExternalProbe.has(.ffmpeg) {
                let clip = try await fx.movingVideo("clip.mp4")
                let info = try unwrap(ExternalProbe.ffprobe(clip, countFrames: true))
                out("      fixture clip: \(info.video[0].width!)x\(info.video[0].height!) \(info.video[0].fps!) fps, \(info.video[0].frames ?? 0) frames, \(Util.formatBytes(TestFile.size(clip)))")
                for crf in [18, 23, 28, 35] {
                    if let u = ReferenceParity.x264(clip, crf: crf, into: dir), let sim = VideoFidelity.similarity(reference: clip, test: u) {
                        out("      x264 CRF \(crf): \(Util.formatBytes(TestFile.size(u))) \(sim.summary)")
                    }
                }
                let vp9 = fx.url("vp9.webm")
                if ExternalProbe.run(ExternalProbe.path(.ffmpeg)!, ["-v", "error", "-nostdin", "-y", "-i", clip.path, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k", vp9.path]).status == 0,
                   let sim = VideoFidelity.similarity(reference: clip, test: vp9) { out("      VP9 CRF 32: \(Util.formatBytes(TestFile.size(vp9))) \(sim.summary)") }
                if let gif = fx.animatedGIF(from: clip), let sim = VideoFidelity.similarity(reference: clip, test: gif, fps: 10) { out("      GIF 10 fps 320 wide: \(Util.formatBytes(TestFile.size(gif))) \(sim.summary)") }
            }
            let wav = try fx.chirp("c.wav", seconds: 3)
            let ref = try unwrap(AudioFidelity.decode(wav))
            func snr(_ u: URL?) -> Double {
                guard let u, var g = AudioFidelity.decode(u) else { return 0 }
                var r = ref
                if abs(g.sampleRate - r.sampleRate) > 0.5, let rs = AudioFidelity.resampled(r, to: g.sampleRate) { r = rs }
                let n = min(r.frames, g.frames); r.channels = r.channels.map { Array($0.prefix(n)) }; g.channels = g.channels.map { Array($0.prefix(n)) }
                return AudioFidelity.match(ref: r, test: g)?.snr ?? 0
            }
            let aac = snr(ReferenceParity.afconvertAAC(wav, kbps: 192, into: dir))
            out("      afconvert AAC 192k: \(String(format: "%.1f", aac)) dB")
            try expect(aac >= ConformanceOracles.audioSNRFloor["m4a"]! + 3, "the AAC floor must sit below the reference \(aac)")
            if ExternalProbe.has(.ffmpeg) {
                let mp3 = snr(ReferenceParity.lameVBR(wav, q: 2, into: dir))
                out("      LAME V2: \(String(format: "%.1f", mp3)) dB")
                try expect(mp3 >= ConformanceOracles.audioSNRFloor["mp3"]! + 3, "the MP3 floor must sit below the reference \(mp3)")
                // Vorbis needs libvorbis: ffmpeg's built-in "vorbis" encoder reaches only about 6 dB SNR on the fixture (and macOS decodes its streams even worse),
                // so an ogg conversion on a Mac without libvorbis must be unavailable, not degraded.
                var targets: [(String, Double)] = [("opus", ConformanceOracles.audioSNRFloor["opus"]!)]
                if Capabilities.shared.has("ff.enc.libvorbis") { targets.append(("ogg", ConformanceOracles.audioSNRFloor["ogg"]!)) } else { out("      ogg: libvorbis is not installed, so audio.to.ogg must stay unavailable on this Mac") }
                for (ext, floor) in targets {
                    let u = fx.audioVariant(of: wav, ext: ext)
                    let s = snr(u)
                    out("      \(ext): \(String(format: "%.1f", s)) dB")
                    if u != nil { try expect(s >= floor + 3, "\(ext) floor \(floor) dB must sit below the reference \(s)") }
                }
            }
        }

        t.register("conformance.harness", "oracles are chosen by priority (engine 100 beats Core's 0 beats the generic fallback), exemptions match by id or prefix, passthrough is declared per operation") {
            let reg = ConformanceRegistry(includeBuiltins: false)
            let meta = OperationMeta.convert("zz.pick", .image, to: "jpg", symbol: "photo", schema: "zz", inputs: ["png"])
            try expectEqual(meta.passthrough, .none, "a conversion is a real transformation unless it declares otherwise")
            try expectEqual(OperationMeta.convert("zz.remux", .video, to: "mkv", symbol: "film", schema: "zz", inputs: ["mp4"], passthrough: .remux).passthrough, .remux)
            try expectEqual(OperationMeta.make("zz.copy", .tools, .image, L10n("Copy"), symbol: "doc.on.doc", schema: "zz", passthrough: .identity).passthrough, .identity)
            func oracle(_ id: String, _ priority: Int) -> ConformanceOracle {
                ConformanceOracle(id: id, priority: priority, match: { $0.id == "zz.pick" }, cases: { _, _ in [] }, verify: { _ in }, proves: "")
            }
            reg.add(oracle("low", 0)); reg.add(oracle("engine", 100)); reg.add(oracle("fallback", -100))
            try expectEqual(reg.oracle(for: meta)?.id, "engine")
            reg.add(oracle("engine", -5))   // same id replaces: the engine oracle now ranks below Core's default (0) and above the fallback (-100)
            try expectEqual(reg.oracle(for: meta)?.id, "low")
            reg.add(oracle("engine", 100))
            try expectEqual(reg.oracle(for: meta)?.id, "engine", "raising the priority again wins again")
            reg.exempt("zz.", reason: "prefix"); reg.exempt("exact.id", reason: "exact")
            try expect(reg.exemption(for: meta) == "prefix", "prefix exemption")
            try expect(reg.exemption(for: OperationMeta.make("exact.id", .tools, .image, L10n("X"), symbol: "x", schema: "s")) == "exact", "exact exemption")
            try expect(reg.exemption(for: OperationMeta.make("exact.id2", .tools, .image, L10n("X"), symbol: "x", schema: "s")) == nil, "an exact id does not match its neighbour")
            var action = OperationMeta.make("action.zz", .actions, .app, L10n("A"), symbol: "bolt", schema: "s")
            action.isAppAction = true
            try expect(ConformanceRegistry.shared.exemption(for: action) != nil, "app actions are exempt by default")
            let link = OperationMeta.link("dl.zz", L10n("D"), symbol: "arrow.down", schema: "s")
            try expect(ConformanceRegistry.shared.exemption(for: link) != nil, "downloads are exempt by default (they need the network)")
        }

        t.register("conformance.harness", "an honest converter passes the generated test; a renamed copy is caught by the real format of its bytes") {
            let honest = FakeImageOp(id: "zz.fake.honest", mode: .honest)
            let none = try await failure(of: honest)
            try expect(none == nil, "an honest JPEG converter must pass, got: \(none ?? "")")
            let renamed = try await failure(of: FakeImageOp(id: "zz.fake.renamed", mode: .renamed))
            try expect(renamed?.contains("its bytes are png") == true, "a PNG renamed to .jpg must be caught by sniffing, got: \(renamed ?? "nothing")")
        }

        t.register("conformance.harness", "right format but wrong picture fails: a blank, a mirrored or a truncated JPEG never passes the fidelity oracle") {
            for mode in [FakeImageOp.Mode.blank, .mirrored, .truncated] {
                let msg = try await failure(of: FakeImageOp(id: "zz.fake.\(mode)", mode: mode))
                try expect(msg != nil, "\(mode) must fail the conformance test")
                out("      \(mode): \(msg ?? "")")
            }
            let blank = try await failure(of: FakeImageOp(id: "zz.fake.blank2", mode: .blank))
            try expect(blank?.contains("PSNR") == true, "a blank picture should be refused by the PSNR floor, got: \(blank ?? "")")
        }

        t.register("conformance.harness", "a quality slider that changes nothing fails the monotonic check; a working one passes") {
            let broken = try await failure(of: FakeImageOp(id: "zz.fake.noq", mode: .ignoresQuality, slider: true))
            try expect(broken?.contains("fake.quality") == true && broken?.contains("must shrink the file") == true, "the dead quality slider must be reported, got: \(broken ?? "nothing")")
            let working = try await failure(of: FakeImageOp(id: "zz.fake.q", mode: .honest, slider: true))
            try expect(working == nil, "a quality slider that works must pass, got: \(working ?? "")")
        }

        t.register("conformance.harness", "a byte copy is refused unless the operation declares passthrough; edited inputs and left-over partial files are refused") {
            let copy = try await failure(of: FakeImageOp(id: "zz.fake.copy", mode: .copiesBytes, target: nil))
            try expect(copy?.contains("byte-identical") == true, "an identical copy must be refused, got: \(copy ?? "nothing")")
            let declared = try await failure(of: FakeImageOp(id: "zz.fake.copy2", mode: .copiesBytes, target: nil, passthrough: .identity))
            try expect(declared == nil, "a declared identity operation may copy bytes, got: \(declared ?? "")")
            let edit = try await failure(of: FakeImageOp(id: "zz.fake.edit", mode: .editsInput, target: nil))
            try expect(edit?.contains("modified its input") == true, "editing the input must be refused, got: \(edit ?? "nothing")")
            let part = try await failure(of: FakeImageOp(id: "zz.fake.part", mode: .leavesPartial, target: nil))
            try expect(part?.contains("in-flight") == true, "leftover .part files must be refused, got: \(part ?? "nothing")")
        }

        t.register("conformance.harness", "an operation no oracle claims fails its test; an exemption with a reason skips it; the real registry gets one generated test per operation") {
            let bare = ConformanceRegistry(includeBuiltins: false)
            let op = FakeImageOp(id: "zz.fake.bare", mode: .honest)
            let msg = try await failure(of: op, registry: bare)
            try expect(msg?.contains("no conformance oracle") == true, "got: \(msg ?? "nothing")")
            bare.exempt("zz.fake.", reason: "test")
            let skipped = try await withOperation(op) { () async throws -> Bool in
                do { try await ConformanceRunner.test(operationID: op.meta.id, registry: bare); return false } catch is TestSkip { return true }
            }
            try expect(skipped, "an exempt operation is skipped, not failed")
            // Generated tests: every non-exempt registered operation has a conformance.<family> case naming it.
            let cases = SelfTestRegistry.shared.cases.filter { $0.suite.hasPrefix("conformance.") }
            for o in OperationRegistry.shared.allOperations() where ConformanceRegistry.shared.exemption(for: o.meta) == nil {
                try expect(cases.contains { $0.name.hasPrefix(o.meta.id + ":") }, "no generated conformance test for \(o.meta.id)")
            }
        }
    }
}

private extension Data {
    func append(to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: self)
    }
}
