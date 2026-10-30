import Foundation
import ImageIO
import CoreGraphics

/// image.to.heic (the wheel's HEIC tile): ImageIO's HEIC writer, judged by readers that share no code with it: the ISO-BMFF brand in the bytes, ImageIO and PSNR
/// after decoding, the quality slider of the schema, the colour profile, the camera orientation and the alpha channel.
enum ImageHeicTests {
    private typealias K = ImageKeys
    private static func t(_ name: String, proves: [String] = [], requires: [String] = [], _ body: @escaping SelfTestBody) {
        ImageTests.test(name, proves: proves, requires: requires, timeout: 120, body)
    }

    /// `ftyp` box at the start: the major brand and the compatible brands.
    static func brands(_ url: URL) -> (major: String, compatible: [String])? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 16, String(decoding: d[4..<8], as: UTF8.self) == "ftyp" else { return nil }
        let size = Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])
        let major = String(decoding: d[8..<12], as: UTF8.self)
        var list: [String] = []
        var i = 16
        while i + 4 <= min(size, d.count) { list.append(String(decoding: d[i..<(i + 4)], as: UTF8.self)); i += 4 }
        return (major, list)
    }

    static func register() {
        t("image.to.heic is on the Convert wheel for a JPG, hidden for a HEIC, and declares no pass-through") {
            let reg = OperationRegistry()
            reg.register(ImageCatalog.operations())
            let jpg = [FileItem(url: URL(fileURLWithPath: "/tmp/a.jpg"), isDirectory: false)], heic = [FileItem(url: URL(fileURLWithPath: "/tmp/a.heic"), isDirectory: false)]
            try expect(reg.entries(wheel: .convert, items: jpg).map(\.id).contains("image.to.heic"), "HEIC offered for a JPG")
            try expect(!reg.entries(wheel: .convert, items: heic).map(\.id).contains("image.to.heic"), "no HEIC to HEIC conversion")
            let op = try unwrap(reg.operation(id: "image.to.heic"))
            try expectEqual(op.meta.targetFormat, "heic"); try expectEqual(op.meta.passthrough, .none); try expectEqual(op.meta.schemaID, "image.convert")
            let q = op.quickOverrides(settings: SettingsData())
            try expectEqual(q[K.format], .string("heic")); try expectEqual(q[K.quality], .int(SettingsData().quality.jpegQuality))
        }

        t("image.to.heic writes a real HEIC (ftyp heic/mif1), decodable by ImageIO, close to the source", proves: ["image.format.type"], requires: ["native.imageio.write.heic"]) {
            let fx = TestFixtures(label: "imgheic1"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 640, height: 480)
            let out = try unwrap(try await ImgT.run("image.to.heic", [src], mode: .quick).outputs.first)
            try expectEqual(out.pathExtension, "heic")
            let b = try unwrap(brands(out), "no ftyp box in the output")
            try expect(["heic", "heix", "mif1"].contains(b.major) || b.compatible.contains("heic") || b.compatible.contains("mif1"), "brands \(b)")
            try expect(b.compatible.contains("heic") || b.compatible.contains("mif1") || b.major == "heic", "an HEVC image brand: \(b)")
            try expectEqual(ImgMetrics.sniff(out), "heic")
            try expect((ImgMetrics.imageIOType(out) ?? "").contains("heic"), "ImageIO type \(String(describing: ImgMetrics.imageIOType(out)))")
            try expect(ImgT.size(out) == (640, 480), "size \(ImgT.size(out))")
            let psnr = try unwrap(ImgMetrics.psnr(src, out)); try expect(psnr >= 31, "PSNR \(psnr) dB")
            try expect(TestFile.size(out) < TestFile.size(src), "smaller than the lossless source: \(TestFile.size(out)) vs \(TestFile.size(src))")
            // Not a copy of anything: the bytes differ from a JPEG made of the same picture, and an unreadable HEIC cannot hide behind the extension.
            let jpg = try await ImgT.convert(src, [K.format: "jpeg"])
            try expect(try Data(contentsOf: jpg) != Data(contentsOf: out), "not the JPEG renamed")
        }

        t("image.to.heic: the quality of the schema moves size and fidelity", proves: ["image.quality"], requires: ["native.imageio.write.heic"]) {
            let fx = TestFixtures(label: "imgheic2"); defer { fx.cleanup() }
            let src = try ImgMetrics.photo(fx, "photo.png", width: 640, height: 480)
            let hi = try unwrap(try await ImgT.run("image.to.heic", [src], [K.quality: 95], mode: .studio).outputs.first)
            let lo = try unwrap(try await ImgT.run("image.to.heic", [src], [K.quality: 30], mode: .studio).outputs.first)
            try expect(TestFile.size(lo) < TestFile.size(hi), "quality 30: \(TestFile.size(lo)) bytes, 95: \(TestFile.size(hi)) bytes")
            let ph = try unwrap(ImgMetrics.psnr(src, hi)), pl = try unwrap(ImgMetrics.psnr(src, lo))
            try expect(ph > pl + 1, "PSNR at 95: \(ph), at 30: \(pl)")
        }

        t("image.to.heic keeps the camera orientation (upright picture), the colour profile and transparency", requires: ["native.imageio.write.heic"]) {
            let fx = TestFixtures(label: "imgheic3"); defer { fx.cleanup() }
            // Orientation 6 (rotate 90 clockwise): stored 80x40, shown 40x80 with the quadrants turned.
            let o6 = try fx.jpeg("o6.jpg", width: 80, height: 40, pattern: .quadrants, quality: 0.95, orientation: 6)
            let upright = try unwrap(try await ImgT.run("image.to.heic", [o6], mode: .quick).outputs.first)
            let tag = ImgT.props(upright)[kCGImagePropertyOrientation] as? Int
            let shown = (tag ?? 1) >= 5 ? (ImgT.size(upright).height, ImgT.size(upright).width) : ImgT.size(upright)
            try expect(shown == (40, 80), "displayed as 40x80: size \(ImgT.size(upright)), tag \(String(describing: tag))")
            try expect(ImgT.isQuadrants(upright, ImageGeometryTests.q["rot90"]!), "turned like the source: \(ImgT.describe(upright))")
            // Display P3 survives.
            let p3 = try ImgT.wideGamut(fx, "p3.png", type: .png, width: 128, height: 64)
            let wide = try unwrap(try await ImgT.run("image.to.heic", [p3], mode: .quick).outputs.first)
            try expect(ImgT.profile(wide).contains("Display P3"), "profile '\(ImgT.profile(wide))'")
            // Alpha.
            let a = try ImgMetrics.photo(fx, "alpha.png", width: 200, height: 100, alpha: true)
            let clear = try unwrap(try await ImgT.run("image.to.heic", [a], mode: .quick).outputs.first)
            try expect(try unwrap(ImgT.pixel(clear, 0.9, 0.5)).a < 20 && (try unwrap(ImgT.pixel(clear, 0.2, 0.5)).a) > 235, "transparent hole stays, picture stays opaque")
        }
    }
}
