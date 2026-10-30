import Foundation
import ImageIO
import CoreGraphics

/// Size, crop, rotation, mirroring and EXIF-orientation oracles: pixel sizes are exact and the quadrant / stripe colours land where they must.
enum ImageGeometryTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], timeout: TimeInterval = 120, _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: timeout, body)
    }

    /// Three bands of red, green and blue: columns (`vertical`) or rows (top = red).
    static func stripes(_ fx: TestFixtures, _ name: String, width: Int, height: Int, vertical: Bool = true) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestFailure(message: "no context", file: #fileID, line: #line)
        }
        let colors: [RGBA] = [.red, .green, .blue]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c.cgColor)
            if vertical {
                let x0 = width * i / 3, x1 = width * (i + 1) / 3
                ctx.fill(CGRect(x: x0, y: 0, width: x1 - x0, height: height))
            } else {
                let y0 = height * i / 3, y1 = height * (i + 1) / 3
                ctx.fill(CGRect(x: 0, y: height - y1, width: width, height: y1 - y0))
            }
        }
        return try fx.writeImage(ctx.makeImage()!, name: name, type: .png)
    }

    static let q: [String: [RGBA]] = [   // TL, TR, BL, BR of the quadrants fixture after each transform
        "identity": [.red, .green, .blue, .yellow],
        "rot90": [.blue, .red, .yellow, .green],
        "rot180": [.yellow, .blue, .green, .red],
        "rot270": [.green, .yellow, .red, .blue],
        "flipH": [.green, .red, .yellow, .blue],
        "flipV": [.blue, .yellow, .red, .green],
        "rot90flipH": [.red, .blue, .green, .yellow]
    ]

    static func register() {
        // MARK: Size

        t("size: longest side, fit, exact, percent and megapixels give exact pixel sizes", proves: ["image.size.pixels", "image.size.long", "image.size.frame", "image.size.percent", "image.size.megapixels"]) {
            let fx = TestFixtures(label: "imgsize"); defer { fx.cleanup() }
            let land = try ImgMetrics.photo(fx, "land.png", width: 600, height: 400)
            let port = try ImgMetrics.photo(fx, "port.png", width: 400, height: 600, seed: 3)
            func size(_ src: URL, _ o: OptionValues) async throws -> (Int, Int) {
                var v = o; v[K.format] = "png"
                let out = try await ImgT.convert(src, v)
                let s = ImgT.size(out); return (s.width, s.height)
            }
            var r = try await size(land, [K.sizeMode: "longEdge", K.sizeLong: 300]); try expect(r == (300, 200), "longEdge landscape \(r)")
            r = try await size(port, [K.sizeMode: "longEdge", K.sizeLong: 300]); try expect(r == (200, 300), "longEdge portrait \(r)")
            r = try await size(land, [K.sizeMode: "fit", K.sizeWidth: 200, K.sizeHeight: 200]); try expect(r == (200, 133), "fit \(r)")
            r = try await size(land, [K.sizeMode: "fit", K.sizeWidth: 0, K.sizeHeight: 100]); try expect(r == (150, 100), "fit with a free width \(r)")
            r = try await size(land, [K.sizeMode: "exact", K.sizeWidth: 100, K.sizeHeight: 100]); try expect(r == (100, 100), "exact \(r)")
            r = try await size(land, [K.sizeMode: "exact", K.sizeWidth: 300, K.sizeHeight: 0]); try expect(r == (300, 200), "exact with a free height keeps the proportions \(r)")
            r = try await size(land, [K.sizeMode: "fill", K.sizeWidth: 100, K.sizeHeight: 100]); try expect(r == (100, 100), "fill \(r)")
            r = try await size(land, [K.sizeMode: "percent", K.sizePercent: 50]); try expect(r == (300, 200), "50% \(r)")
            r = try await size(land, [K.sizeMode: "percent", K.sizePercent: 200]); try expect(r == (1200, 800), "200% \(r)")
            let mp = try await size(land, [K.sizeMode: "megapixels", K.sizeMegapixels: 0.12])
            try expect(abs(Double(mp.0 * mp.1) - 120_000) < 1_500, "0.12 MP gave \(mp)")
            try expect(abs(Double(mp.0) / Double(mp.1) - 1.5) < 0.01, "proportions kept \(mp)")
        }

        t("size: pictures are not enlarged unless allowed", proves: ["image.size.upscale"]) {
            let fx = TestFixtures(label: "imgup"); defer { fx.cleanup() }
            let small = try ImgMetrics.photo(fx, "small.png", width: 300, height: 200)
            var out = try await ImgT.convert(small, [K.format: "png", K.sizeMode: "longEdge", K.sizeLong: 1000])
            try expect(ImgT.size(out) == (300, 200), "not enlarged: \(ImgT.size(out))")
            out = try await ImgT.convert(small, [K.format: "png", K.sizeMode: "longEdge", K.sizeLong: 1000, K.upscale: true])
            try expect(ImgT.size(out) == (1000, 667), "enlarged: \(ImgT.size(out))")
            out = try await ImgT.convert(small, [K.format: "png", K.sizeMode: "fit", K.sizeWidth: 900, K.sizeHeight: 900])
            try expect(ImgT.size(out) == (300, 200), "fit does not enlarge: \(ImgT.size(out))")
            out = try await ImgT.convert(small, [K.format: "png", K.sizeMode: "fit", K.sizeWidth: 900, K.sizeHeight: 900, K.upscale: true])
            try expect(ImgT.size(out) == (900, 600), "fit enlarges when allowed: \(ImgT.size(out))")
        }

        t("size: a huge picture is shrunk straight from the file and still matches a scaled copy of the source") {
            let fx = TestFixtures(label: "imgbig"); defer { fx.cleanup() }
            let big = try ImgT.bigJPEG(fx, width: 4000, height: 3000)
            let out = try await ImgT.convert(big, [K.format: "png", K.sizeMode: "longEdge", K.sizeLong: 1000])
            try expect(ImgT.size(out) == (1000, 750), "size \(ImgT.size(out))")
            let psnr = try unwrap(ImgMetrics.psnrScaled(source: big, output: out))
            try expect(psnr >= 38, "reduced decode PSNR \(psnr)")
        }

        t("size fill: the frame is filled and the overflow is cropped, not stretched") {
            let fx = TestFixtures(label: "imgfill"); defer { fx.cleanup() }
            let src = try stripes(fx, "s.png", width: 600, height: 400)
            let fill = try await ImgT.convert(src, [K.format: "png", K.sizeMode: "fill", K.sizeWidth: 100, K.sizeHeight: 100])
            try expect(ImgT.size(fill) == (100, 100), "fill size")
            // Centre 400 px of 600 are kept: the green band covers 200 of those 400 px (25% to 75%), red 100 px on the left.
            try expect(TestImage.close(ImgT.pixel(fill, 0.30, 0.5), .green, tolerance: 20), "x = 30% is green when filled")
            try expect(TestImage.close(ImgT.pixel(fill, 0.10, 0.5), .red, tolerance: 20), "x = 10% is red")
            let stretch = try await ImgT.convert(src, [K.format: "png", K.sizeMode: "exact", K.sizeWidth: 100, K.sizeHeight: 100])
            try expect(TestImage.close(ImgT.pixel(stretch, 0.30, 0.5), .red, tolerance: 20), "x = 30% is red when stretched")
        }

        // MARK: Orientation, rotation, mirroring

        t("camera orientation 1 to 8 is baked into the pixels and the tag is gone", proves: ["image.orient.bake"]) {
            let fx = TestFixtures(label: "imgorient"); defer { fx.cleanup() }
            let expected: [Int: String] = [1: "identity", 2: "flipH", 3: "rot180", 4: "flipV", 6: "rot90", 8: "rot270"]
            for (o, key) in expected {
                let src = try fx.jpeg("o\(o).jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: o)
                let out = try await ImgT.convert(src, [K.format: "png"])
                let swapped = o >= 5
                try expect(ImgT.size(out) == (swapped ? (40, 80) : (80, 40)), "orientation \(o): size \(ImgT.size(out))")
                try expect(ImgT.isQuadrants(out, q[key]!), "orientation \(o) should look like \(key): \(ImgT.describe(out))")
                let tag = ImgT.props(out)[kCGImagePropertyOrientation] as? Int
                try expect(tag == nil || tag == 1, "orientation tag after baking: \(String(describing: tag))")
            }
        }

        t("camera orientation 5 and 7 (the transposes) are applied", proves: ["image.orient.bake"]) {
            let fx = TestFixtures(label: "imgorient2"); defer { fx.cleanup() }
            let src5 = try fx.jpeg("o5.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 5)
            let out5 = try await ImgT.convert(src5, [K.format: "png"])
            try expect(ImgT.isQuadrants(out5, [.red, .blue, .green, .yellow]), "orientation 5: \(ImgT.describe(out5))")
            let src7 = try fx.jpeg("o7.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 7)
            let out7 = try await ImgT.convert(src7, [K.format: "png"])
            try expect(ImgT.isQuadrants(out7, [.yellow, .green, .blue, .red]), "orientation 7: \(ImgT.describe(out7))")
        }

        t("turning camera rotation off keeps the pixels and records the tag where the format can", proves: ["image.orient.bake"]) {
            let fx = TestFixtures(label: "imgorient3"); defer { fx.cleanup() }
            let src = try fx.jpeg("o6.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 6)
            let out = try await ImgT.convert(src, [K.format: "jpeg", K.autoOrient: false])
            try expect(ImgT.size(out) == (80, 40), "pixels stay as stored: \(ImgT.size(out))")
            try expectEqual(ImgT.props(out)[kCGImagePropertyOrientation] as? Int, 6, "tag recorded")
            let gif = try await ImgT.convert(src, [K.format: "bmp", K.autoOrient: false])
            try expect(ImgT.size(gif) == (40, 80), "BMP cannot carry the tag, so the rotation is baked in: \(ImgT.size(gif))")
        }

        t("rotate: 90, 180 and 270 turn clockwise", proves: ["image.rotate.quadrants"]) {
            let fx = TestFixtures(label: "imgrot"); defer { fx.cleanup() }
            let src = try fx.png("q.png", width: 80, height: 40, pattern: .quadrants)
            for (deg, key, size) in [(0, "identity", (80, 40)), (90, "rot90", (40, 80)), (180, "rot180", (80, 40)), (270, "rot270", (40, 80))] {
                let out = try await ImgT.convert(src, [K.format: "png", K.rotate: .int(deg)])
                try expect(ImgT.size(out) == size, "\(deg): size \(ImgT.size(out))")
                try expect(ImgT.isQuadrants(out, q[key]!), "\(deg): \(ImgT.describe(out))")
            }
        }

        t("mirror: horizontal, vertical and combined with a rotation", proves: ["image.flip.quadrants", "image.rotate.quadrants"]) {
            let fx = TestFixtures(label: "imgflip"); defer { fx.cleanup() }
            let src = try fx.png("q.png", width: 80, height: 40, pattern: .quadrants)
            let h = try await ImgT.convert(src, [K.format: "png", K.flipH: true])
            try expect(ImgT.isQuadrants(h, q["flipH"]!), "flipH \(ImgT.describe(h))")
            let v = try await ImgT.convert(src, [K.format: "png", K.flipV: true])
            try expect(ImgT.isQuadrants(v, q["flipV"]!), "flipV \(ImgT.describe(v))")
            let both = try await ImgT.convert(src, [K.format: "png", K.flipH: true, K.flipV: true])
            try expect(ImgT.isQuadrants(both, q["rot180"]!), "flipH + flipV = 180: \(ImgT.describe(both))")
            let rf = try await ImgT.convert(src, [K.format: "png", K.rotate: 90, K.flipH: true])
            try expect(ImgT.size(rf) == (40, 80) && ImgT.isQuadrants(rf, q["rot90flipH"]!), "rotate then mirror \(ImgT.describe(rf))")
        }

        t("pure rotations and mirrors lose nothing: PNG pixels are exact") {
            let fx = TestFixtures(label: "imgexact"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 160, height: 120)
            let a = try await ImgT.convert(src, [K.format: "png", K.rotate: 90])
            let b = try await ImgT.convert(a, [K.format: "png", K.rotate: 270])
            try expect(ImgMetrics.identical(src, b), "90 then 270 returns the original pixels")
            let c = try await ImgT.convert(src, [K.format: "png", K.flipH: true])
            let d = try await ImgT.convert(c, [K.format: "png", K.flipH: true])
            try expect(ImgMetrics.identical(src, d), "mirror twice returns the original pixels")
        }

        // MARK: Crop

        t("crop by ratio: the largest window of that ratio, anchored left, centre, right, top or bottom", proves: ["image.crop.pixels", "image.crop.ratio", "image.crop.anchor"]) {
            let fx = TestFixtures(label: "imgcrop"); defer { fx.cleanup() }
            let wide = try stripes(fx, "wide.png", width: 600, height: 400)
            func crop(_ src: URL, _ anchor: String, ratio: String = "1:1") async throws -> URL {
                try await ImgT.convert(src, [K.format: "png", K.cropMode: "ratio", K.cropRatio: .string(ratio), K.cropAnchor: .string(anchor)])
            }
            let centre = try await crop(wide, "center")
            try expect(ImgT.size(centre) == (400, 400), "1:1 of 600x400 is 400x400, got \(ImgT.size(centre))")
            try expect(TestImage.close(ImgT.pixel(centre, 0.1, 0.5), .red, tolerance: 12) && TestImage.close(ImgT.pixel(centre, 0.5, 0.5), .green, tolerance: 12)
                       && TestImage.close(ImgT.pixel(centre, 0.9, 0.5), .blue, tolerance: 12), "centre keeps red | green | blue")
            let left = try await crop(wide, "left")
            try expect(TestImage.close(ImgT.pixel(left, 0.25, 0.5), .red, tolerance: 12) && TestImage.close(ImgT.pixel(left, 0.75, 0.5), .green, tolerance: 12), "left anchor")
            let right = try await crop(wide, "right")
            try expect(TestImage.close(ImgT.pixel(right, 0.25, 0.5), .green, tolerance: 12) && TestImage.close(ImgT.pixel(right, 0.75, 0.5), .blue, tolerance: 12), "right anchor")
            let tall = try stripes(fx, "tall.png", width: 400, height: 600, vertical: false)
            let top = try await crop(tall, "top")
            try expect(ImgT.size(top) == (400, 400), "top size \(ImgT.size(top))")
            try expect(TestImage.close(ImgT.pixel(top, 0.5, 0.25), .red, tolerance: 12) && TestImage.close(ImgT.pixel(top, 0.5, 0.75), .green, tolerance: 12), "top anchor")
            let bottom = try await crop(tall, "bottom")
            try expect(TestImage.close(ImgT.pixel(bottom, 0.5, 0.25), .green, tolerance: 12) && TestImage.close(ImgT.pixel(bottom, 0.5, 0.75), .blue, tolerance: 12), "bottom anchor")
            let r169 = try await crop(wide, "center", ratio: "16:9")
            try expect(ImgT.size(r169) == (600, 338), "16:9 of 600x400: \(ImgT.size(r169))")
            let r916 = try await crop(wide, "center", ratio: "9:16")
            try expect(ImgT.size(r916) == (225, 400), "9:16 of 600x400: \(ImgT.size(r916))")
            let r21 = try await crop(wide, "center", ratio: "21:9")
            try expect(ImgT.size(r21) == (600, 257), "21:9 of 600x400: \(ImgT.size(r21))")
        }

        t("crop to the main subject returns the requested ratio from the picture content", proves: ["image.crop.anchor"]) {
            let fx = TestFixtures(label: "imgsubj"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 600, height: 400)
            let out = try await ImgT.convert(src, [K.format: "png", K.cropMode: "ratio", K.cropRatio: "1:1", K.cropAnchor: "subject"])
            try expect(ImgT.size(out) == (400, 400), "subject crop size \(ImgT.size(out))")
        }

        t("crop: uniform borders are trimmed away exactly", proves: ["image.crop.trim", "image.crop.pixels"]) {
            let fx = TestFixtures(label: "imgtrim"); defer { fx.cleanup() }
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            ctx.setFillColor(RGBA.red.cgColor); ctx.fill(CGRect(x: 30, y: 20, width: 90, height: 110))      // 90 x 110 at x 30, top 20
            ctx.setFillColor(RGBA.blue.cgColor); ctx.fill(CGRect(x: 120, y: 20, width: 50, height: 110))    // content: 140 x 110
            let src = try fx.writeImage(ctx.makeImage()!, name: "border.png", type: .png)
            let out = try await ImgT.convert(src, [K.format: "png", K.cropMode: "autoTrim", K.cropTrim: 8])
            try expect(ImgT.size(out) == (140, 110), "trimmed to \(ImgT.size(out))")
            try expect(TestImage.close(ImgT.pixel(out, 0.1, 0.5), .red, tolerance: 6) && TestImage.close(ImgT.pixel(out, 0.9, 0.5), .blue, tolerance: 6), "content kept")
            // A picture whose corners differ has no border to remove and is left alone.
            let quad = try fx.png("quad.png", width: 90, height: 60, pattern: .quadrants)
            let none = try await ImgT.convert(quad, [K.format: "png", K.cropMode: "autoTrim"])
            try expect(ImgT.size(none) == (90, 60), "nothing to trim")
        }

        t("crop: a rectangle takes exactly those pixels, zero width or height means to the edge", proves: ["image.crop.rect", "image.crop.pixels"]) {
            let fx = TestFixtures(label: "imgrect"); defer { fx.cleanup() }
            let src = try fx.png("q.png", width: 200, height: 100, pattern: .quadrants)
            let out = try await ImgT.convert(src, [K.format: "png", K.cropMode: "rect", K.cropX: 50, K.cropY: 20, K.cropW: 100, K.cropH: 60])
            try expect(ImgT.size(out) == (100, 60), "rect size \(ImgT.size(out))")
            try expect(ImgT.isQuadrants(out, [.red, .green, .blue, .yellow], tolerance: 6), "rect content \(ImgT.describe(out))")
            let edge = try await ImgT.convert(src, [K.format: "png", K.cropMode: "rect", K.cropX: 120, K.cropY: 0, K.cropW: 0, K.cropH: 0])
            try expect(ImgT.size(edge) == (80, 100), "to the edge \(ImgT.size(edge))")
            try expect(TestImage.close(ImgT.pixel(edge, 0.5, 0.25), .green, tolerance: 6) && TestImage.close(ImgT.pixel(edge, 0.5, 0.75), .yellow, tolerance: 6), "edge content")
            let outside = try await ImgT.convert(src, [K.format: "png", K.cropMode: "rect", K.cropX: 900, K.cropY: 900, K.cropW: 50, K.cropH: 50])
            try expect(ImgT.size(outside).width > 0, "a rectangle outside the picture does not crash")
        }

        t("crop happens before rotation and resizing: crop, rotate and scale in one run") {
            let fx = TestFixtures(label: "imgchain"); defer { fx.cleanup() }
            let src = try stripes(fx, "wide.png", width: 600, height: 400)
            let out = try await ImgT.convert(src, [K.format: "png", K.cropMode: "ratio", K.cropRatio: "16:9", K.cropAnchor: "left", K.rotate: 90, K.sizeMode: "longEdge", K.sizeLong: 100])
            // 16:9 of 600x400 -> 600x338; rotated 338x600; longest side 100 -> 56x100.
            try expect(ImgT.size(out) == (56, 100), "chain size \(ImgT.size(out))")
        }

        t("odd sizes survive every geometry path: 1x1, 3x5, 4001x3") {
            let fx = TestFixtures(label: "imgodd"); defer { fx.cleanup() }
            for (w, h) in [(1, 1), (3, 5), (4001, 3), (7, 2001)] {
                let src = try fx.png("odd\(w)x\(h).png", width: w, height: h, pattern: .gradient)
                let same = try await ImgT.convert(src, [K.format: "png"])
                try expect(ImgT.size(same) == (w, h), "\(w)x\(h) same size: \(ImgT.size(same))")
                let rot = try await ImgT.convert(src, [K.format: "jpeg", K.rotate: 90, K.cropMode: "ratio", K.cropRatio: "1:1"])
                let side = min(w, h)
                try expect(ImgT.size(rot) == (side, side), "\(w)x\(h) square crop: \(ImgT.size(rot))")
                let small = try await ImgT.convert(src, [K.format: "png", K.sizeMode: "percent", K.sizePercent: 5])
                try expect(ImgT.size(small).width >= 1 && ImgT.size(small).height >= 1, "\(w)x\(h) never collapses to zero")
            }
        }
    }
}
