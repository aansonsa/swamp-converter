import Foundation
import ImageIO
import CoreGraphics

/// What the Studio shows around an image conversion: the source probe, size estimate, summary chips, before / after preview, presets, schema sanity and capabilities.
enum ImageStudioTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    static func register() {
        t("probe: size after rotation, location, camera, transparency and frames without decoding pixels") {
            let fx = TestFixtures(label: "imgprobe"); defer { fx.cleanup() }
            let rotated = try fx.jpeg("r.jpg", width: 80, height: 40, pattern: .quadrants, orientation: 6, gps: true)
            let info = await ImageSourceProbe().probe(FileItem(url: rotated, isDirectory: false))
            try expectEqual(info.int("image.width"), 40); try expectEqual(info.int("image.height"), 80)
            try expectEqual(info.bool("image.hasGPS"), true)
            try expectEqual(info.int("image.orientation"), 6)
            try expectEqual(info.int("image.frames"), 1)
            try expect(info.chips.contains { $0.text.contains("40 × 80") }, "size chip \(info.chips.map(\.text))")
            try expect(info.chips.contains { $0.text.contains("SwampCam") }, "camera chip")
            try expect(!info.warnings.isEmpty, "warns about location / rotation")
            let alpha = try ImgMetrics.photo(fx, "a.png", width: 60, height: 40, alpha: true)
            let ai = await ImageSourceProbe().probe(FileItem(url: alpha, isDirectory: false))
            try expectEqual(ai.bool("image.alpha"), true)
            let gif = try ImgT.animatedGIF(fx, "g.gif", frames: 4)
            let gi = await ImageSourceProbe().probe(FileItem(url: gif, isDirectory: false))
            try expectEqual(gi.int("image.frames"), 4)
            let svg = try fx.svg("v.svg", width: 64, height: 48)
            let si = await ImageSourceProbe().probe(FileItem(url: svg, isDirectory: false))
            try expect(si.int("image.width") == 128 && si.int("image.height") == 96, "SVG probe is at 2x: \(String(describing: si.int("image.width")))")
        }

        t("probe: the sizes of an icon are not frames of an animation") {
            let fx = TestFixtures(label: "imgprobeico"); defer { fx.cleanup() }
            let png = try ImgMetrics.photo(fx, "sq.png", width: 300, height: 300)
            let ico = try await ImgT.convert(png, [K.format: "ico"])
            let info = await ImageSourceProbe().probe(FileItem(url: ico, isDirectory: false))
            try expectEqual(info.int("image.frames"), 1)
            try expectEqual(info.int("image.width"), 256)
            let r = try await ImgT.run("image.to.png", [ico], [K.frames: "all"], mode: .studio)
            try expectEqual(r.outputs.count, 1, "an icon is one picture")
            try expect(ImgT.size(try unwrap(r.outputs.first)) == (256, 256), "the largest size")
        }

        t("probe is cheap even for a big picture") {
            let fx = TestFixtures(label: "imgprobe2"); defer { fx.cleanup() }
            let big = try ImgT.bigJPEG(fx, "big.jpg", width: 5000, height: 3500)
            let t0 = Date()
            let info = await ImageSourceProbe().probe(FileItem(url: big, isDirectory: false))
            let dt = Date().timeIntervalSince(t0)
            try expectEqual(info.int("image.width"), 5000)
            try expect(dt < 0.25, "probe took \(Int(dt * 1000)) ms")
        }

        t("estimate: positive, follows format, quality, size and the limit") {
            let fx = TestFixtures(label: "imgest"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png")
            let item = FileItem(url: src, isDirectory: false)
            let info = await ImageSourceProbe().probe(item)
            let op = ImgT.op("image.to.jpg")
            let schema = op.optionSchema(for: [item])
            func est(_ o: OptionValues) -> Int64 {
                let v = schema.resolve(layers: [o], source: info).values
                return op.estimate(options: v, items: [item], source: info)?.bytes ?? 0
            }
            let q30 = est([K.format: "jpeg", K.quality: 30]), q60 = est([K.format: "jpeg", K.quality: 60]), q90 = est([K.format: "jpeg", K.quality: 90])
            try expect(q30 > 0 && q30 < q60 && q60 < q90, "quality order \(q30) \(q60) \(q90)")
            let half = est([K.format: "jpeg", K.sizeMode: "percent", K.sizePercent: 50])
            try expect(half < q90 / 2, "half size is smaller: \(half) vs \(q90)")
            let capped = est([K.format: "jpeg", K.targetKB: 20])
            try expect(capped <= 20 * 1024, "the limit caps the estimate: \(capped)")
            let png = est([K.format: "png"]), pal = est([K.format: "png", K.pngPalette: true])
            try expect(pal < png, "palette PNG estimate is smaller")
            // Rough but not absurd: within a factor of 3 of the real JPEG.
            let real = TestFile.size(try await ImgT.convert(src, [K.format: "jpeg"]))
            try expect(Double(q90) > Double(real) / 3 && Double(q90) < Double(real) * 3, "estimate \(q90) vs real \(real)")
            try expect(op.estimate(options: [:], items: [], source: nil) == nil, "no items, no estimate")
        }

        t("summary chips describe the choices") {
            let op = ImgT.op("image.to.jpg")
            let chips = op.summaryChips(options: [K.format: "jpeg", K.quality: 82, K.sizeMode: "longEdge", K.sizeLong: 1600, K.rotate: 90, K.mdMode: "strip", K.cropMode: "ratio", K.cropRatio: "4:5"], source: nil)
            for needle in ["JPEG", "Q82", "1600 px", "90°", "4:5"] { try expect(chips.contains(needle), "chips \(chips) contain \(needle)") }
            try expect(chips.contains { $0.contains("metadata") || $0.contains("метаданных") }, "metadata chip \(chips)")
        }

        t("validation notes: icon sizes larger than the picture, location staying in HEIC") {
            let op = ImgT.op("image.to.ico")
            var info = SourceInfo(url: URL(fileURLWithPath: "/tmp/x.png"), kind: .image)
            info.facts["image.width"] = .int(64); info.facts["image.height"] = .int(64); info.facts["image.hasGPS"] = .bool(true)
            let m = op.validate(options: [K.format: "ico", K.icoSizes: "256,64"], source: info)
            try expect(m.contains { $0.id == "image.ico.small" }, "small picture note")
            let h = op.validate(options: [K.format: "heic", K.mdMode: "keep"], source: info)
            try expect(h.contains { $0.id == "image.gps.kept" }, "location note")
            let none = op.validate(options: [K.format: "png"], source: info)
            try expect(none.isEmpty, "nothing to say for PNG")
        }

        t("preview: before and after at the requested size, the options visible in the sample") {
            let fx = TestFixtures(label: "imgprev"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 1200, height: 800)
            let item = FileItem(url: src, isDirectory: false)
            let op = ImgT.op("image.to.jpg")
            let info = await ImageSourceProbe().probe(item)
            let o = op.optionSchema(for: [item]).resolve(layers: [[K.format: "jpeg", K.quality: 20, K.sizeMode: "percent", K.sizePercent: 50, K.gray: true]], source: info).values
            let p = try unwrap(try await op.preview(items: [item], options: o, source: info, time: nil, maxPixel: 300))
            let before = try unwrap(p.before), after = try unwrap(p.after)
            try expect(max(before.width, before.height) <= 300 && max(before.width, before.height) >= 290, "before is \(before.width)x\(before.height)")
            try expect(abs(Double(after.width) / Double(before.width) - 0.5) < 0.02, "after is half of before: \(after.width) vs \(before.width)")
            try expect(p.sampleOutputBytes ?? 0 > 0, "sample bytes measured")
            // Grayscale shows: decode the sample's pixels.
            let px = try unwrap(ImgMetrics.pixels(after))
            let c = px.rgb(px.width / 2, px.height / 2)
            try expect(abs(c.0 - c.1) <= 3 && abs(c.1 - c.2) <= 3, "grayscale visible in the preview \(c)")
            func sample(_ quality: Int) async throws -> Int64 {
                let v = op.optionSchema(for: [item]).resolve(layers: [[K.format: "jpeg", K.quality: .int(quality), K.sizeMode: "percent", K.sizePercent: 50]], source: info).values
                return try unwrap(try await op.preview(items: [item], options: v, source: info, time: nil, maxPixel: 300)?.sampleOutputBytes)
            }
            let lowBytes = try await sample(20), highBytes = try await sample(95)
            try expect(highBytes > lowBytes, "higher quality, bigger sample: \(lowBytes) vs \(highBytes)")
            let none = try await op.preview(items: [], options: o, source: info, time: nil, maxPixel: 300)
            try expect(none == nil, "nothing to preview without items")
        }

        t("preview of a big picture is quick and does not decode it twice at full size") {
            let fx = TestFixtures(label: "imgprev2"); defer { fx.cleanup() }
            let big = try ImgT.bigJPEG(fx, "big.jpg", width: 6000, height: 4000)
            let item = FileItem(url: big, isDirectory: false)
            let op = ImgT.op("image.to.jpg")
            let o = op.optionSchema(for: [item]).resolve(layers: [[K.format: "jpeg"]]).values
            let t0 = Date()
            let p = try unwrap(try await op.preview(items: [item], options: o, source: nil, time: nil, maxPixel: 800))
            let dt = Date().timeIntervalSince(t0)
            try expect(try unwrap(p.before).width <= 800, "before is small")
            try expect(dt < 1.5, "preview took \(Int(dt * 1000)) ms")
        }

        // MARK: Presets and schema sanity

        t("built-in presets: unique ids, known keys, valid values, grouped") {
            let presets = ImagePresets.builtins
            try expect(presets.count >= 15, "\(presets.count) presets")
            try expectEqual(Set(presets.map(\.id)).count, presets.count, "unique ids")
            for p in presets {
                try expect(p.id.hasPrefix("builtin."), "\(p.id) is built in")
                let schema = p.targetID == ImageSchemas.pdfID ? ImageSchemas.mergePDF(items: []) : ImageSchemas.convert(items: [])
                try expect(["image.convert", "image.pdf"].contains(p.targetID), "\(p.id) target \(p.targetID)")
                for key in p.values.keys { try expect(schema.field(key) != nil, "\(p.id): '\(key)' is not a field of \(schema.id)") }
                let resolved = schema.resolve(layers: [p.values])
                for key in p.values.keys where !resolved.inactive.contains(key) {
                    // An active preset value must survive resolution unchanged (it was not clamped or replaced).
                    let a = p.values.storage[key], b = resolved.values[key]
                    try expect(a == b || a?.asDouble == b?.asDouble || a?.asString == b?.asString, "\(p.id): \(key) \(String(describing: a)) became \(String(describing: b))")
                }
                try expect(!p.name.en.isEmpty && !p.name.ru.isEmpty, "\(p.id) has both names")
            }
        }

        t("every built-in convert preset runs and writes what it promises") {
            let fx = TestFixtures(label: "imgpresets"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 1000, height: 700)
            for p in ImagePresets.builtins where p.targetID == ImageSchemas.convertID {
                let fmt = p.values.string(K.format, "jpeg")
                if fmt == "webp", !Capabilities.shared.has("tool.cwebp") { continue }
                if fmt == "icns", !Capabilities.shared.has("tool.iconutil") { continue }
                if fmt == "heic", !Capabilities.shared.has("native.imageio.write.heic") { continue }
                if fmt == "avif", !Capabilities.shared.has("native.imageio.write.avif") { continue }
                let r = try await ImgT.run("image.to.jpg", [src], p.values, mode: .studio)
                let out = try unwrap(r.outputs.first, "\(p.id) produced nothing")
                let expectSniff = fmt == "same" ? "png" : (fmt == "jp2" ? "jp2" : fmt)
                try expectEqual(ImgMetrics.sniff(out), expectSniff, "\(p.id) writes \(expectSniff)")
                try expect(TestFile.size(out) > 0, "\(p.id) is not empty")
            }
        }

        t("built-in PDF presets run through Images to PDF") {
            let fx = TestFixtures(label: "imgpresetspdf"); defer { fx.cleanup() }
            let a = try ImgMetrics.photo(fx, "a.png", width: 400, height: 300), b = try ImgMetrics.photo(fx, "b.png", width: 300, height: 400, seed: 2)
            for p in ImagePresets.builtins where p.targetID == ImageSchemas.pdfID {
                let r = try await ImgT.run("image.merge.pdf", [a, b], p.values, mode: .studio)
                let out = try unwrap(r.outputs.first)
                try expectEqual(PDFProbe.pageCount(out), 2, p.id)
            }
        }

        t("the Web JPEG, Under 1 MB and Share-safe presets do what their names say") {
            let fx = TestFixtures(label: "imgpresets2"); defer { fx.cleanup() }
            let tagged = try ImageColourTests.taggedJPEG(fx, "t.jpg", width: 3000, height: 2000)
            let web = try unwrap(ImagePresets.builtins.first { $0.id == "builtin.img.web.jpeg" })
            let out = try unwrap(try await ImgT.run("image.to.jpg", [tagged], web.values, mode: .studio).outputs.first)
            try expectEqual(ImgMetrics.sniff(out), "jpeg"); try expect(ImgT.size(out) == (2048, 1365), "Web JPEG size \(ImgT.size(out))")
            try expectEqual(ImgT.jpegFrame(out)?.marker, 0xC2, "progressive")
            try expect(!ImgT.hasGPS(out) && ImgT.make(out) == "SwampCam", "no location, camera kept")
            let noise = try ImgMetrics.photo(fx, "noisy.jpg", width: 2400, height: 1800)
            let one = try unwrap(ImagePresets.builtins.first { $0.id == "builtin.img.upload1mb" })
            let o1 = try unwrap(try await ImgT.run("image.to.jpg", [noise], one.values, mode: .studio).outputs.first)
            try expect(TestFile.size(o1) <= 1024 * 1024, "under 1 MB: \(TestFile.size(o1))")
            let priv = try unwrap(ImagePresets.builtins.first { $0.id == "builtin.img.private" })
            let o2 = try unwrap(try await ImgT.run("image.to.jpg", [tagged], priv.values, mode: .studio).outputs.first)
            try expect(!ImgT.hasGPS(o2) && ImgT.make(o2) == nil, "share-safe removes metadata")
            try expectEqual(ImgMetrics.sniff(o2), "jpeg", "same format")
        }

        t("schema sanity: unique keys, defaults inside ranges, picker defaults among their options") {
            for schema in [ImageSchemas.convert(items: []), ImageSchemas.mergePDF(items: [])] {
                let fields = schema.allFields
                // image.pdf reuses img.dpi and img.quality / img.alpha.bg with its own labels, so duplicates are only checked per schema.
                try expectEqual(Set(fields.map(\.key)).count, fields.count, "\(schema.id): unique keys")
                for f in fields {
                    try expect(!f.label.en.isEmpty && !f.label.ru.isEmpty, "\(f.key) has EN and RU labels")
                    let d = f.defaultValue.resolve(nil)
                    switch f.kind {
                    case .picker(let opts), .segmented(let opts):
                        try expect(opts.contains { $0.value == d.asString }, "\(f.key): default '\(d.displayText)' is one of the options")
                        try expect(opts.allSatisfy { !$0.label.en.isEmpty }, "\(f.key): option labels")
                    case .slider(let s): try expect((d.asDouble ?? -1) >= s.min && (d.asDouble ?? -1) <= s.max, "\(f.key): slider default in range")
                    case .number(let n):
                        if let lo = n.min { try expect((d.asDouble ?? -1) >= lo, "\(f.key): number default >= min") }
                        if let hi = n.max { try expect((d.asDouble ?? 1e18) <= hi, "\(f.key): number default <= max") }
                    default: break
                    }
                }
            }
        }

        t("schema: fields only appear for the formats they apply to") {
            let schema = ImageSchemas.convert(items: [])
            func active(_ o: OptionValues, _ key: String) -> Bool { schema.resolve(layers: [o]).isActive(key) }
            try expect(active([K.format: "jpeg"], K.progressive) && !active([K.format: "png"], K.progressive), "progressive is a JPEG option")
            try expect(active([K.format: "png"], K.pngPalette) && !active([K.format: "jpeg"], K.pngPalette), "palette is a PNG option")
            try expect(active([K.format: "tiff"], K.tiffCompression) && !active([K.format: "png"], K.tiffCompression), "TIFF compression")
            try expect(active([K.format: "ico"], K.icoSizes) && !active([K.format: "jpeg"], K.icoSizes), "icon sizes")
            try expect(!active([K.format: "png"], K.quality) && active([K.format: "heic"], K.quality), "quality only for lossy formats")
            try expect(active([K.format: "jpeg", K.sizeMode: "longEdge"], K.sizeLong) && !active([K.format: "jpeg", K.sizeMode: "original"], K.sizeLong), "size fields follow the mode")
            try expect(active([K.format: "jpeg"], K.alphaBackground) && !active([K.format: "png"], K.alphaBackground), "background only where transparency is lost")
            try expect(!active([K.format: "jpeg", K.subsampling: "444"], K.progressive) || !Capabilities.shared.has("tool.ffmpeg"), "progressive is off with 4:4:4")
        }

        t("capabilities: native write support is reported per format") {
            ImageCapabilities.register()
            for f in ["jpeg", "png", "tiff", "gif", "bmp"] { try expect(Capabilities.shared.has("native.imageio.write.\(f)"), "\(f) is writable on every Mac") }
            try expect(!ImageFormat.writesNatively("webp"), "WebP is never written by ImageIO")
            try expect(ImageFormat.imageIOType("webp") == nil && ImageFormat.imageIOType("jxl") == nil, "no ImageIO route for WebP / JPEG XL")
        }

        t("WebP without cwebp is reported, not faked") {
            let fx = TestFixtures(label: "imgnowebp"); defer { fx.cleanup() }
            let src = try fx.png("in.png", width: 40, height: 30)
            let item = FileItem(url: src, isDirectory: false)
            let have = ToolLocator.shared.has(.cwebp)
            try expectEqual(ImgT.op("image.to.webp").availability(for: [item], tools: ToolLocator.shared).isAvailable, have, "the WebP slice follows cwebp")
            let webp = FileItem(url: fx.url("x.webp"), isDirectory: false)
            try expectEqual(ImgT.op("image.compress").availability(for: [webp], tools: ToolLocator.shared).isAvailable, have, "editing a WebP in place needs cwebp too")
            try expect(ImgT.op("image.compress").availability(for: [item], tools: ToolLocator.shared).isAvailable, "editing a PNG needs nothing")
            let image = fx.cgImage(width: 40, height: 30)
            let err = try await expectThrows("encoding WebP without a tool must say so") { _ = try ImageEncoder.encodeSync(image, format: "webp", options: [:]) }
            try expect(!ConversionError.describe(err).isEmpty, "message")
        }
    }
}
