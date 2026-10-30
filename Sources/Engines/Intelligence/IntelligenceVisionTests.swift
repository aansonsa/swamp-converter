import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// C. Background removal. A drawn subject (shaded red ellipse with a stem) on a sky / ground backdrop; Vision decides what the subject is, the test reads the
// PNG back with ImageIO and counts alpha: opaque only inside the subject, transparent in the corners, colours of the kept pixels equal the source.

enum IntelligenceVisionTests {
    static let width = 800, height = 600
    /// Subject ellipse in top-left pixel coordinates.
    static let subject = CGRect(x: 280, y: 600 - 410, width: 240, height: 260)

    static func subjectImage(second: Bool = false) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let sky = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.55, green: 0.7, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.85, green: 0.9, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.5, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 160))
        func apple(centerX: CGFloat) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: centerX - 120, y: 150, width: 240, height: 260)); ctx.clip()
            let shade = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 1, green: 0.35, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.55, green: 0.05, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(shade, startCenter: CGPoint(x: centerX - 40, y: 330), startRadius: 5, endCenter: CGPoint(x: centerX, y: 280), endRadius: 160, options: [])
            ctx.restoreGState()
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.15, alpha: 1)); ctx.fill(CGRect(x: centerX - 5, y: 400, width: 12, height: 50))
        }
        if second {
            apple(centerX: 170); apple(centerX: 620)
        } else {
            apple(centerX: 400)
        }
        return ctx.makeImage()!
    }

    struct Alpha { var width: Int, height: Int, px: [UInt8]
        func a(_ x: Int, _ y: Int) -> Int { Int(px[(y * width + x) * 4 + 3]) }
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4, a = max(Int(px[i + 3]), 1)
            return (Int(px[i]) * 255 / a, Int(px[i + 1]) * 255 / a, Int(px[i + 2]) * 255 / a)
        }
        var opaqueFraction: Double { Double(stride(from: 3, to: px.count, by: 4).filter { px[$0] > 127 }.count) / Double(width * height) }
        var partial: Int { stride(from: 3, to: px.count, by: 4).filter { px[$0] > 0 && px[$0] < 255 }.count }
        var bounds: CGRect {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where a(x, y) > 127 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            return maxX < 0 ? .zero : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    /// Premultiplied RGBA bytes of a decoded file (origin top-left).
    static func readAlpha(_ url: URL) throws -> Alpha {
        let src = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), img = try unwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let ctx = try unwrap(CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let data = try unwrap(ctx.data)
        return Alpha(width: img.width, height: img.height, px: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4)))
    }

    static func register() {
        let t = SelfTestRegistry.shared
        let needsVision = ["native.vision.foreground"]

        t.register("intelligence", "image.removebg: the subject stays opaque, the background becomes transparent, kept pixels are not resampled", requires: needsVision) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.writeImage(subjectImage(), name: "subject.png", type: .png)
            let before = try IntelTest.sha256(src)
            let result = try await IntelTest.run("image.removebg", [src])
            let out = try unwrap(result.outputs.first)
            try expectEqual(out.lastPathComponent, "subject (cutout).png")
            try expectEqual(try IntelTest.sha256(src), before, "the original must not change")
            try expectEqual(TestFile.magic(out, 4), [0x89, 0x50, 0x4E, 0x47], "must be a real PNG")
            let info = try unwrap(TestImage.info(of: out))
            try expectEqual(info.type, UTType.png.identifier)
            try expect(info.hasAlpha, "PNG must have an alpha channel")
            try expectEqual(info.width, width); try expectEqual(info.height, height)
            let a = try readAlpha(out)
            for (x, y) in [(5, 5), (794, 5), (5, 594), (794, 594), (100, 300), (700, 300)] { try expect(a.a(x, y) < 10, "background at (\(x),\(y)) should be transparent, alpha \(a.a(x, y))") }
            for (x, y) in [(400, 320), (350, 280), (450, 360)] { try expect(a.a(x, y) > 245, "subject at (\(x),\(y)) should be opaque, alpha \(a.a(x, y))") }
            let frac = a.opaqueFraction
            try expect(frac > 0.07 && frac < 0.25, "opaque share \(frac) (an ellipse of this size covers about 10%)")
            let box = a.bounds
            try expect(abs(box.minX - subject.minX) < 14 && abs(box.maxX - subject.maxX) < 14 && abs(box.minY - subject.minY) < 40 && abs(box.maxY - subject.maxY) < 14, "bounds \(box) vs \(subject)")
            // The colours of kept pixels are the source colours.
            let source = try readAlpha(src)
            for (x, y) in [(400, 320), (350, 280), (450, 360), (380, 250)] {
                let p = a.rgb(x, y), q = source.rgb(x, y)
                try expect(abs(p.0 - q.0) <= 2 && abs(p.1 - q.1) <= 2 && abs(p.2 - q.2) <= 2, "pixel (\(x),\(y)) changed: \(p) vs \(q)")
            }
        }

        t.register("intelligence", "image.removebg: crop, padding, colour, feather, size and subject-number options each change the result", requires: needsVision) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.writeImage(subjectImage(), name: "subject.png", type: .png)
            let base = try readAlpha(try unwrap(try await IntelTest.run("image.removebg", [src]).outputs.first))
            let box = base.bounds

            let crop = try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.cropToSubject: true], mode: .studio).outputs.first)
            let cs = try unwrap(TestImage.size(of: crop))
            try expect(abs(Double(cs.width) - box.width) <= 4 && abs(Double(cs.height) - box.height) <= 4, "crop \(cs) vs subject box \(box)")
            let c = try readAlpha(crop)
            try expect(c.a(cs.width / 2, cs.height / 2) > 245 && c.a(1, 1) < 20, "cropped picture keeps the subject, corner stays transparent")

            let padded = try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.cropToSubject: true, CutoutKeys.padding: 20], mode: .studio).outputs.first)
            let ps = try unwrap(TestImage.size(of: padded))
            try expectEqual(ps.width, cs.width + 40, "padding adds 20 px on each side")
            try expectEqual(ps.height, cs.height + 40)
            let p = try readAlpha(padded)
            try expect(p.a(10, 10) < 5 && p.a(ps.width / 2, ps.height / 2) > 245, "padding is transparent")

            let green = try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.background: "color", CutoutKeys.backgroundColor: "#00FF00"], mode: .studio).outputs.first)
            let g = try readAlpha(green)
            try expectEqual(g.a(5, 5), 255, "a coloured background is opaque")
            let corner = g.rgb(5, 5)
            try expect(corner.0 <= 3 && corner.1 >= 252 && corner.2 <= 3, "background colour \(corner)")
            try expect(g.a(400, 320) == 255 && g.rgb(400, 320).0 > 150, "subject untouched by the fill")

            let sharp = base.partial
            let soft = try readAlpha(try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.feather: 12], mode: .studio).outputs.first)).partial
            try expect(soft > sharp * 2, "feathering should widen the soft edge: \(soft) vs \(sharp)")

            let small = try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.maxPixel: "512"], mode: .studio).outputs.first)
            let ss = try unwrap(TestImage.size(of: small))
            try expectEqual(max(ss.width, ss.height), 512, "longest side")
            try expectEqual(ss.width, 512); try expectEqual(ss.height, 384)

            // Subject numbers: two apples, number 1 keeps one, the other number keeps the other, "all" keeps both.
            let two = try fx.writeImage(subjectImage(second: true), name: "two.png", type: .png)
            let both = try readAlpha(try unwrap(try await IntelTest.run("image.removebg", [two], mode: .studio).outputs.first))
            guard both.a(170, 320) > 245 && both.a(620, 320) > 245 else { try skipTest("Vision found one object in the two-apple picture on this Mac") }
            func sides(_ extra: String) async throws -> (left: Bool, right: Bool) {
                let r = try readAlpha(try unwrap(try await IntelTest.run("image.removebg", [two], extra: [CutoutKeys.instances: .string(extra)], mode: .studio).outputs.first))
                return (r.a(170, 320) > 245, r.a(620, 320) > 245)
            }
            let one = try await sides("1"), other = try await sides("2")
            try expect(one.left != one.right, "subject 1 must be exactly one apple: \(one)")
            try expect(other.left != other.right && other.left != one.left, "subject 2 must be the other apple: \(other) vs \(one)")
        }

        t.register("intelligence", "image.removebg: no subject gives a calm message, cancellation is honoured, options map to the engine", requires: needsVision) {
            let flat = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            flat.setFillColor(CGColor(gray: 0.5, alpha: 1)); flat.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            let image = flat.makeImage()!
            let error = try await expectThrows { _ = try await CutoutEngine.cutout(image, options: CutoutOptions()) }
            try expect(ConversionError.describe(error).contains("No subject"), ConversionError.describe(error))

            let task = Task { try await CutoutEngine.cutout(subjectImage(), options: CutoutOptions()) }
            task.cancel()
            let outcome = await task.result
            if case .failure(let e) = outcome { try expect(e is CancellationError, "\(e)") }

            var o = OptionValues(); o[CutoutKeys.cropToSubject] = true; o[CutoutKeys.padding] = 8; o[CutoutKeys.background] = "color"; o[CutoutKeys.backgroundColor] = "#102030"
            o[CutoutKeys.feather] = 3; o[CutoutKeys.maxPixel] = "1024"; o[CutoutKeys.instances] = "1, 3"
            let c = RemoveBackgroundOperation.cutoutOptions(o)
            try expect(c.cropToSubject && c.padding == 8 && c.backgroundHex == "#102030" && c.feather == 3 && c.maxPixel == 1024 && c.instanceIndexes == [1, 3])
            let rgb = try unwrap(CutoutEngine.rgb(fromHex: "#102030"))
            try expectClose(Double(rgb.r), 16.0 / 255, tolerance: 0.001)
            try expect(CutoutEngine.rgb(fromHex: "red") == nil)
            // Huge pictures are scaled down before Vision.
            let big = CutoutEngine.scaledDown(image, longestSide: 100)
            try expectEqual(max(big.width, big.height), 100)
            for f in CutoutSchemas.removeBackground(items: []).allFields { try expect(!f.oracle.isEmpty, "\(f.key) has no oracle") }
        }

        t.register("intelligence", "image.removebg: a large picture is cancelled within 200 ms", requires: needsVision, timeout: 120) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let w = 5000, h = 3750
            let ctx = try unwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(subjectImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
            let src = try fx.writeImage(try unwrap(ctx.makeImage()), name: "large.png", type: .png)
            let started = IntelSignal()
            let op = try IntelTest.operation("image.removebg")
            let items = [FileItem(url: src)]
            let job = OperationContext.testing(op, items: items)
            job.onProgress = { f, _, _ in if (f ?? 0) >= 0.1 { started.fire() } }
            defer { job.cleanupTemp() }
            let task = Task { try await op.execute(items: items, ctx: job) }
            let running = await started.wait(timeout: 30)
            try expect(running, "the job never started")
            let t0 = Date()
            task.cancel()
            let outcome = await task.result
            let took = Date().timeIntervalSince(t0)
            guard case .failure(let error) = outcome else { throw TestFailure(message: "the job finished before it could be cancelled; use a larger picture", file: #fileID, line: #line) }
            try expect(error is CancellationError, "\(error)")
            out("      cancelled in \(String(format: "%.1f", took * 1000)) ms")
            try expect(took < 0.2, "cancellation took \(took) s")
            try expect(TestFile.partials(in: fx.root).isEmpty && !TestFile.exists(fx.url("large (cutout).png")), "no partial output may remain")
        }

        t.register("intelligence", "image.removebg: WebP output keeps the alpha (needs cwebp)", requires: needsVision + ["tool.cwebp"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.writeImage(subjectImage(), name: "subject.png", type: .png)
            let out = try unwrap(try await IntelTest.run("image.removebg", [src], extra: [CutoutKeys.format: "webp"], mode: .studio).outputs.first)
            try expectEqual(out.pathExtension, "webp")
            let head = TestFile.magic(out, 12)
            try expect(Array(head[0..<4]) == Array("RIFF".utf8) && Array(head[8..<12]) == Array("WEBP".utf8), "must be a real WebP: \(head)")
            let a = try readAlpha(out)
            try expect(a.a(5, 5) < 10 && a.a(400, 320) > 240, "alpha must survive WebP")
        }
    }
}
