import Foundation
import CoreGraphics
import ImageIO

// Small helpers the oracles share.

enum ConformanceSchema {
    /// The first field whose key ends in one of `names` after a dot ("image.quality" matches "quality").
    static func field(_ schema: OptionSchema, last names: [String]) -> OptionField? {
        schema.allFields.first { f in names.contains { f.key == $0 || f.key.hasSuffix("." + $0) } }
    }

    /// The first ACTIVE field of the run that is one of `names` (exact key or "<anything>.<name>"), tried in the order given, with its numeric range.
    @MainActor static func knob(of run: ConformanceRun, names: [String], exact: Bool = false) -> (field: OptionField, range: ClosedRange<Double>)? {
        let fields = schema(of: run).allFields
        for name in names {
            let hit = fields.first { f in
                !run.inactive.contains(f.key) && (f.key == name || (!exact && f.key.hasSuffix("." + name))) && range(f) != nil
            }
            if let hit, let r = range(hit) { return (hit, r) }
        }
        return nil
    }

    /// Numeric range of a slider / stepper / number field.
    static func range(_ f: OptionField) -> ClosedRange<Double>? {
        switch f.kind {
        case .slider(let s): return s.min...s.max
        case .stepper(let s): return Double(s.min)...Double(s.max)
        case .number(let n): if let lo = n.min, let hi = n.max { return lo...hi } else { return nil }
        default: return nil
        }
    }

    /// The schema of `run`'s operation for its inputs (what Studio would show).
    @MainActor static func schema(of run: ConformanceRun) -> OptionSchema {
        run.operation.optionSchema(for: FileItem.items(run.inputs))
    }
}

extension ConformanceRun {
    /// Exactly one output file; fails with a clear message otherwise.
    func sole(_ what: String = "output") throws -> URL {
        guard outputs.count == 1 else { throw TestFailure(message: "expected exactly one \(what) file, got \(outputs.count): \(outputs.map(\.lastPathComponent))", file: #fileID, line: #line) }
        return outputs[0]
    }

    func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> TestFailure { TestFailure(message: message, file: "\(file)", line: line) }

    /// The resolved value of an option, when the operation has that key and it is active.
    func option(_ key: String) -> OptionValue? { options[key] }
}

extension ImageFidelity {
    /// `img` centred on a white canvas of the given size (for comparing a square icon frame with a rectangular source).
    static func padded(_ img: RasterImage, width: Int, height: Int) -> RasterImage {
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        let alpha = [UInt8](repeating: 255, count: width * height)
        let ox = (width - img.width) / 2, oy = (height - img.height) / 2
        for y in 0..<img.height { for x in 0..<img.width {
            let dx = x + ox, dy = y + oy
            guard dx >= 0, dy >= 0, dx < width, dy < height else { continue }
            let s = (y * img.width + x) * 3, d = (dy * width + dx) * 3
            rgb[d] = img.rgb[s]; rgb[d + 1] = img.rgb[s + 1]; rgb[d + 2] = img.rgb[s + 2]
        } }
        return RasterImage(width: width, height: height, rgb: rgb, alpha: alpha)
    }

    /// Sizes of every frame of an ICO / ICNS / multi-image file.
    static func frameSizes(_ url: URL) -> [(width: Int, height: Int)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any], let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (w, h)
        }
    }

    /// The metadata dictionaries of the first frame (EXIF, GPS, TIFF, IPTC ...).
    static func properties(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }
}
