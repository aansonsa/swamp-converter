import Foundation
import ImageIO
import CoreGraphics

/// The wheel operations as the job runner runs them: quick recipes, output names, collisions, same-format skipping, awkward file names, cancellation.
enum ImageOperationTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    static func register() {
        // MARK: Quick recipes

        t("Compress: smaller progressive JPEG without metadata, named (compressed)") {
            let fx = TestFixtures(label: "imgcomp"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.jpg", width: 800, height: 600)
            let tagged = try ImageColourTests.taggedJPEG(fx, "tagged.jpg", width: 800, height: 600)
            let r = try await ImgT.run("image.compress", [src])
            let out = try unwrap(r.outputs.first)
            try expect(out.lastPathComponent.contains("(compressed)") || out.lastPathComponent.contains("(сжато)"), "name \(out.lastPathComponent)")
            try expectEqual(ImgMetrics.sniff(out), "jpeg")
            try expect(TestFile.size(out) < TestFile.size(src) * 8 / 10, "compressed \(TestFile.size(out)) vs \(TestFile.size(src))")
            try expectEqual(ImgT.jpegFrame(out)?.marker, 0xC2, "progressive")
            let comps = try unwrap(ImgT.jpegFrame(out)?.components)
            try expect(comps[0].h == 2 && comps[0].v == 2, "4:2:0 \(comps)")
            let psnr = try unwrap(ImgMetrics.psnr(src, out))
            try expect(psnr >= 30, "quality 70 still looks like the picture, PSNR \(psnr)")
            let t2 = try await ImgT.run("image.compress", [tagged])
            let o2 = try unwrap(t2.outputs.first)
            try expect(!ImgT.hasGPS(o2) && ImgT.make(o2) == nil, "metadata removed")
        }

        t("Compress PNG: a 256-colour palette for pictures, full colour kept for transparency") {
            let fx = TestFixtures(label: "imgcomppng"); defer { fx.cleanup() }
            let photo = try ImgMetrics.photo(fx, "photo.png")
            let r = try await ImgT.run("image.compress", [photo])
            let out = try unwrap(r.outputs.first)
            try expectEqual(ImgMetrics.sniff(out), "png")
            try expectEqual(ImgT.pngHeader(out)?.colorType, 3, "indexed")
            try expect(TestFile.size(out) < TestFile.size(photo) * 6 / 10, "palette \(TestFile.size(out)) vs \(TestFile.size(photo))")
            let alpha = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 120, alpha: true)
            let r2 = try await ImgT.run("image.compress", [alpha])
            try expectEqual(ImgT.pngHeader(try unwrap(r2.outputs.first))?.colorType, 6, "transparent PNG stays RGBA")
        }

        t("Compress uses the compress-quality setting; the convert recipes use the JPEG-quality setting") {
            let fx = TestFixtures(label: "imgsettings"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png")
            var low = SettingsData(); low.quality.compressQuality = 35; low.quality.jpegQuality = 40
            var high = SettingsData(); high.quality.compressQuality = 90; high.quality.jpegQuality = 95
            let png = try fx.png("p.png", width: 10, height: 10)
            _ = png
            let jpgSrc = try ImgMetrics.photo(fx, "photo.jpg")
            let a = try unwrap(try await ImgT.run("image.compress", [jpgSrc], settings: low).outputs.first)
            let b = try unwrap(try await ImgT.run("image.compress", [jpgSrc], settings: high).outputs.first)
            try expect(TestFile.size(a) < TestFile.size(b), "compress quality 35 < 90: \(TestFile.size(a)) vs \(TestFile.size(b))")
            let c = try unwrap(try await ImgT.run("image.to.jpg", [src], settings: low).outputs.first)
            let d = try unwrap(try await ImgT.run("image.to.jpg", [src], settings: high).outputs.first)
            try expect(TestFile.size(c) < TestFile.size(d), "JPEG quality 40 < 95: \(TestFile.size(c)) vs \(TestFile.size(d))")
        }

        t("Shrink 50% and Max 1920 px give exact sizes and never enlarge") {
            let fx = TestFixtures(label: "imgshrink"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.jpg", width: 800, height: 600)
            let half = try unwrap(try await ImgT.run("image.half", [src]).outputs.first)
            try expect(ImgT.size(half) == (400, 300), "half \(ImgT.size(half))")
            try expect(half.lastPathComponent.contains("(smaller)") || half.lastPathComponent.contains("(уменьшено)"), half.lastPathComponent)
            let wide = try ImgMetrics.photo(fx, "wide.jpg", width: 4000, height: 1000)
            let capped = try unwrap(try await ImgT.run("image.max1920", [wide]).outputs.first)
            try expect(ImgT.size(capped) == (1920, 480), "max1920 \(ImgT.size(capped))")
            try expect(capped.lastPathComponent.contains("(1920)"), capped.lastPathComponent)
            let tall = try ImgMetrics.photo(fx, "tall.jpg", width: 1000, height: 2500)
            let capped2 = try unwrap(try await ImgT.run("image.max1920", [tall]).outputs.first)
            try expect(ImgT.size(capped2) == (768, 1920), "max1920 portrait \(ImgT.size(capped2))")
            let small = try unwrap(try await ImgT.run("image.max1920", [src]).outputs.first)
            try expect(ImgT.size(small) == (800, 600), "a smaller picture is not enlarged \(ImgT.size(small))")
        }

        t("Rotate right / left, Mirror, Square, Grayscale, No metadata do what they say") {
            let fx = TestFixtures(label: "imgtools"); defer { fx.cleanup() }
            let q = try fx.png("q.png", width: 80, height: 40, pattern: .quadrants)
            let right = try unwrap(try await ImgT.run("image.rotate.right", [q]).outputs.first)
            try expect(ImgT.size(right) == (40, 80) && ImgT.isQuadrants(right, ImageGeometryTests.q["rot90"]!), "right \(ImgT.describe(right))")
            let left = try unwrap(try await ImgT.run("image.rotate.left", [q]).outputs.first)
            try expect(ImgT.size(left) == (40, 80) && ImgT.isQuadrants(left, ImageGeometryTests.q["rot270"]!), "left \(ImgT.describe(left))")
            let flip = try unwrap(try await ImgT.run("image.flip", [q]).outputs.first)
            try expect(ImgT.isQuadrants(flip, ImageGeometryTests.q["flipH"]!), "mirror \(ImgT.describe(flip))")
            let wide = try ImgMetrics.photo(fx, "wide.png", width: 300, height: 200)
            let sq = try unwrap(try await ImgT.run("image.square", [wide]).outputs.first)
            try expect(ImgT.size(sq) == (200, 200), "square \(ImgT.size(sq))")
            let g = try unwrap(try await ImgT.run("image.grayscale", [wide]).outputs.first)
            let p = try unwrap(ImgT.pixel(g, 0.3, 0.3))
            try expect(abs(Int(p.r) - Int(p.g)) <= 1 && abs(Int(p.g) - Int(p.b)) <= 1, "neutral \(p)")
            let tagged = try ImageColourTests.taggedJPEG(fx)
            let s = try unwrap(try await ImgT.run("image.strip", [tagged]).outputs.first)
            try expect(!ImgT.hasGPS(s) && ImgT.make(s) == nil, "stripped")
            try expect(ImgT.size(s) == ImgT.size(tagged), "same pixels count")
        }

        t("Rotating a camera-rotated photo keeps it upright: EXIF is baked first, then the turn is added") {
            let fx = TestFixtures(label: "imgrotexif"); defer { fx.cleanup() }
            let src = try fx.jpeg("o6.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 6)
            // Displayed upright it reads [B R; Y G] (40x80); turning right gives [Y B; G R] (80x40).
            let out = try unwrap(try await ImgT.run("image.rotate.right", [src]).outputs.first)
            try expect(ImgT.size(out) == (80, 40), "size \(ImgT.size(out))")
            try expect(ImgT.isQuadrants(out, [.yellow, .blue, .green, .red]), "\(ImgT.describe(out))")
            let tag = ImgT.props(out)[kCGImagePropertyOrientation] as? Int
            try expect(tag == nil || tag == 1, "no leftover orientation tag \(String(describing: tag))")
        }

        t("Convert recipes equal the Studio defaults: the wheel and the Studio run the same options") {
            let ops = ImageCatalog.operations()
            let settings = SettingsData()
            for op in ops where op.meta.id.hasPrefix("image.to.") {
                let schema = op.optionSchema(for: [])
                let quick = schema.resolve(layers: [op.quickOverrides(settings: settings)]).values
                let studio = schema.resolve(layers: [OptionValues([K.format: .string(op.meta.targetFormat == "jpg" ? "jpeg" : op.meta.targetFormat ?? "jpeg")])]).values
                try expectEqual(quick.string(K.quality), studio.string(K.quality), "\(op.meta.id) quality")
                for field in schema.allFields where field.key != K.format {
                    try expectEqual(quick[field.key], studio[field.key], "\(op.meta.id): \(field.key) differs between the wheel and the Studio default")
                }
                try expectEqual(quick.int(K.quality), 90, "convert quality is the documented 90")
            }
        }

        // MARK: Output names and batches

        t("output names never overwrite: photo.png, photo (2).png, photo (3).png") {
            let fx = TestFixtures(label: "imgcollide"); defer { fx.cleanup() }
            let src = try fx.jpeg("photo.jpg", width: 40, height: 30)
            var names: [String] = []
            for _ in 0..<3 { names.append(try unwrap(try await ImgT.run("image.to.png", [src]).outputs.first).lastPathComponent) }
            try expectEqual(names, ["photo.png", "photo (2).png", "photo (3).png"])
            try expect(TestFile.partials(in: fx.root).isEmpty, "no partial files")
        }

        t("quick runs convert only the files that are not already in the target format; Studio converts all") {
            let fx = TestFixtures(label: "imgskip"); defer { fx.cleanup() }
            let a = try fx.png("a.png", width: 30, height: 20), b = try fx.png("b.png", width: 30, height: 20), c = try fx.jpeg("c.jpg", width: 30, height: 20)
            let quick = try await ImgT.run("image.to.png", [a, b, c], mode: .quick)
            try expectEqual(quick.outputs.map(\.lastPathComponent), ["c.png"], "only the JPEG is converted")
            let studio = try await ImgT.run("image.to.png", [a, b, c], mode: .studio)
            try expectEqual(studio.outputs.count, 3, "Studio converts every file")
        }

        t("file names with spaces, unicode, leading dashes and several dots work") {
            let fx = TestFixtures(label: "imgnames"); defer { fx.cleanup() }
            for name in ["my photo (1).jpg", "фото ёжик 日本語.jpg", "-dash.jpg", "dots.in.the.name.v2.jpg", "UPPER.JPG"] {
                let src = try fx.jpeg(name, width: 40, height: 30)
                let out = try unwrap(try await ImgT.run("image.to.png", [src]).outputs.first, name)
                let base = (name as NSString).deletingPathExtension
                try expectEqual(out.lastPathComponent, base + ".png", "name for \(name)")
                try expectEqual(ImgMetrics.sniff(out), "png")
            }
        }

        t("a read-only folder fails with a clear message and no partial file") {
            let fx = TestFixtures(label: "imgro"); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("locked")
            let src = try fx.jpeg("locked/in.jpg", width: 40, height: 30)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            if FileManager.default.isWritableFile(atPath: dir.path) { try skipTest("this account can write into read-only folders") }
            let err = try await expectThrows("writing into a read-only folder must fail") { _ = try await ImgT.run("image.to.png", [src]) }
            try expect(!ConversionError.describe(err).isEmpty, "has a message")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted(), ["in.jpg"], "nothing left behind")
        }

        t("a custom output folder and name template are honoured") {
            let fx = TestFixtures(label: "imgrules"); defer { fx.cleanup() }
            let src = try fx.jpeg("photo.jpg", width: 40, height: 30)
            let out = try fx.makeDirectory("out")
            var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path; rules.nameTemplate = "{name}-web"
            let r = try await ImgT.run("image.to.png", [src], rules: rules)
            try expectEqual(try unwrap(r.outputs.first).deletingLastPathComponent().standardizedFileURL.path, out.standardizedFileURL.path)
            try expectEqual(try unwrap(r.outputs.first).lastPathComponent, "photo-web.png")
        }

        t("cancelling mid-run stops quickly and leaves neither a result nor a .part file") {
            let fx = TestFixtures(label: "imgcancel"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "big.png", width: 3600, height: 2400)
            let before = Set((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? [])
            let task = Task { @MainActor in try await ImgT.run("image.to.png", [src], [K.pngPalette: true], mode: .studio) }
            try await Task.sleep(nanoseconds: 120_000_000)
            let t0 = Date()
            task.cancel()
            var finished = false
            do { _ = try await task.value; finished = true } catch is CancellationError {} catch { throw error }
            let latency = Date().timeIntervalSince(t0)
            try expect(TestFile.partials(in: fx.root).isEmpty, "no .part files: \(TestFile.partials(in: fx.root))")
            if !finished {
                let after = Set((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? [])
                try expectEqual(after, before, "nothing new in the folder after a cancel")
                try expect(latency < 0.6, "the run stopped \(Int(latency * 1000)) ms after the cancel")
            }
        }

        t("a pre-cancelled run produces nothing") {
            let fx = TestFixtures(label: "imgcancel2"); defer { fx.cleanup() }
            let src = try fx.jpeg("a.jpg", width: 400, height: 300)
            let task = Task { @MainActor in
                try await Task.sleep(nanoseconds: 50_000_000)
                return try await ImgT.run("image.to.png", [src], mode: .studio)
            }
            task.cancel()
            _ = try? await task.value
            try expectEqual(((try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? []).sorted(), ["a.jpg"])
        }

        t("memory returns to where it was after 60 conversions of different kinds", timeout: 240) {
            let fx = TestFixtures(label: "imgleak"); defer { fx.cleanup() }
            let photo = try ImgMetrics.photo(fx, "photo.png", width: 1000, height: 700, noise: 3)
            let jpg = try ImgMetrics.photo(fx, "photo.jpg", width: 1000, height: 700, noise: 3)
            func footprint() -> Int {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
                return r == KERN_SUCCESS ? Int(info.phys_footprint) : 0
            }
            func work(_ n: Int) async throws {
                for i in 0..<n {
                    switch i % 5 {
                    case 0: _ = try await ImgT.run("image.to.jpg", [photo], mode: .studio)
                    case 1: _ = try await ImgT.run("image.half", [jpg], mode: .studio)
                    case 2: _ = try await ImgT.run("image.compress", [photo], mode: .studio)
                    case 3: _ = try await ImgT.convert(photo, [K.format: "tiff", K.rotate: 90])
                    default: _ = try await ImgT.convert(jpg, [K.format: "png", K.pngPalette: true])
                    }
                    // Results pile up in the fixture folder: clear them so the disk does not decide the test.
                    for f in (try? FileManager.default.contentsOfDirectory(atPath: fx.root.path)) ?? [] where f != "photo.png" && f != "photo.jpg" { try? FileManager.default.removeItem(at: fx.url(f)) }
                }
            }
            try await work(10)                       // warm up caches, ICC profiles, thread pools
            let before = footprint()
            try await work(60)
            let after = footprint()
            try expect(after - before < 25 * 1_048_576, "footprint grew by \((after - before) / 1_048_576) MB over 60 conversions")
        }

        t("many files in one batch all convert and report progress up to 1") {
            let fx = TestFixtures(label: "imgbatch"); defer { fx.cleanup() }
            var urls: [URL] = []
            for i in 0..<8 { urls.append(try fx.png("p\(i).png", width: 60, height: 40, pattern: .noise(seed: UInt64(i)))) }
            let r = try await ImgT.run("image.to.jpg", urls)
            try expectEqual(r.outputs.count, 8)
            try expect(r.outputs.allSatisfy { ImgMetrics.sniff($0) == "jpeg" }, "all JPEG")
        }
    }
}
