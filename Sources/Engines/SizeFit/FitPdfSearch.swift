import Foundation

// The pure part of the PDF fit: how "how much to reduce" maps onto image resolution and JPEG quality, and the search over that single knob.
// The knob is a level `t`: 0 is "no loss that matters" (300 dpi, quality 0.85), 1 is "as small as images get" (40 dpi). Smaller t = better picture, bigger file.

enum PdfFitCurve {
    struct Settings: Equatable, Sendable {
        var dpi: Int
        var quality: Double
    }

    /// Anchors of the vector-preserving path (Quartz filter on the images, text and drawings untouched): the 300 -> 200 -> 150 -> 110 -> 72 dpi ladder
    /// of the brief, with a "very sharp" step before it (t < 0) and a last resort after it. Quality falls with the resolution.
    static let imageAnchors: [(t: Double, dpi: Double, quality: Double)] = [
        (-0.4, 600, 1.0), (-0.2, 600, 0.95), (0.0, 300, 0.85), (0.2, 200, 0.80), (0.4, 150, 0.75), (0.6, 110, 0.70), (0.8, 72, 0.60), (1.0, 40, 0.40)
    ]
    /// Anchors of the picture path (pages turned into JPEG pictures; text no longer selectable except for the invisible layer).
    static let pageAnchors: [(t: Double, dpi: Double, quality: Double)] = [
        (0.0, 220, 0.80), (0.2, 170, 0.75), (0.4, 130, 0.70), (0.6, 100, 0.62), (0.8, 72, 0.52), (1.0, 40, 0.40)
    ]
    static let imageRange: ClosedRange<Double> = -0.4...1.0
    static let pageRange: ClosedRange<Double> = 0.0...1.0

    /// Resolution and JPEG quality for level `t`: linear in the logarithm of the dpi, linear in quality; quality never below `minQuality` (percent).
    static func settings(level t: Double, anchors: [(t: Double, dpi: Double, quality: Double)], minQuality: Int) -> Settings {
        let clamped = min(max(t, anchors.first!.t), anchors.last!.t)
        var lo = anchors[0], hi = anchors[anchors.count - 1]
        for i in 0..<(anchors.count - 1) where clamped >= anchors[i].t && clamped <= anchors[i + 1].t { lo = anchors[i]; hi = anchors[i + 1]; break }
        let f = hi.t == lo.t ? 0 : (clamped - lo.t) / (hi.t - lo.t)
        let dpi = exp(log(lo.dpi) + (log(hi.dpi) - log(lo.dpi)) * f)
        let q = lo.quality + (hi.quality - lo.quality) * f
        return Settings(dpi: Int(dpi.rounded()), quality: max(q, Double(min(max(minQuality, 1), 100)) / 100))
    }

    static func imageSettings(level t: Double, minQuality: Int) -> Settings { settings(level: t, anchors: imageAnchors, minQuality: minQuality) }
    static func pageSettings(level t: Double, minQuality: Int) -> Settings { settings(level: t, anchors: pageAnchors, minQuality: minQuality) }
}

enum PdfFitSearch {
    struct Outcome: Sendable {
        var level: Double
        var bytes: Int64
    }

    /// Finds the smallest level (best picture) whose result fits `targetBytes`, stopping early inside the band [fillGoal, 1] x target.
    /// `measure(level)` produces the result for that level and returns its size (larger level = smaller result). Returns nil when even `range.upperBound` is too big.
    /// Grid steps of 0.2 bracket the answer, then a log-linear interpolation (kept at least 10% inside the bracket) closes in; at most `maxRefinements` extra runs.
    static func search(targetBytes: Int64, range: ClosedRange<Double>, maxRefinements: Int = 6,
                       measure: (Double) throws -> Int64) throws -> Outcome? {
        let target = Double(targetBytes)
        let goalLow = target * FitTuning.fillGoal
        let aim = target * FitTuning.aimFraction
        var tooBig: (t: Double, bytes: Double)?
        var fit: (t: Double, bytes: Double)?

        // Grid: range.lowerBound, then 0, 0.2, ... up to range.upperBound (the same sample is never measured twice).
        var grid = [range.lowerBound]
        var g = 0.0
        while g <= range.upperBound + 1e-9 { if g > range.lowerBound + 1e-9 { grid.append(min(g, range.upperBound)) }; g += 0.2 }
        for t in grid {
            let bytes = Double(try measure(t))
            if bytes <= target { fit = (t, bytes); break } else { tooBig = (t, bytes) }
        }
        guard var best = fit else { return nil }
        guard var high = tooBig else { return Outcome(level: best.t, bytes: Int64(best.bytes)) }   // fits at the very best setting
        var low = best
        for _ in 0..<maxRefinements {
            if best.bytes >= goalLow { break }
            // `high` is the too-big side (smaller t), `low` the fitting side (larger t).
            let span = low.t - high.t
            guard span > 0.004 else { break }
            let lnHigh = log(max(high.bytes, 1)), lnLow = log(max(low.bytes, 1))
            var f = lnHigh > lnLow ? (lnHigh - log(aim)) / (lnHigh - lnLow) : 0.5
            f = min(max(f, 0.1), 0.9)
            let t = high.t + span * f
            let bytes = Double(try measure(t))
            if bytes <= target {
                low = (t, bytes)
                if bytes > best.bytes { best = (t, bytes) }
            } else {
                high = (t, bytes)
            }
        }
        return Outcome(level: best.t, bytes: Int64(best.bytes))
    }
}
