import Foundation
import CoreGraphics

/// The search for "the best picture that fits N bytes", as a small state machine: the search asks for one probe at a time (a scale and a quality),
/// the caller encodes it however it likes (synchronously in tests, with `await` in the engine) and reports the size. Pure and deterministic.
///
/// Strategy (the one that looks best, not just the one that is smallest):
///  1. quality search at full size: lowest allowed quality first; if even that is too big, resizing is needed (when allowed);
///  2. otherwise the highest quality is tried; if it fits we are done; if not, a binary search finds the highest quality that fits;
///  3. resizing: the long edge shrinks by 20% per step at a good quality (75, or the floor if that is higher) until a step fits,
///     then the scale is bisected inside the last step (the picture keeps as many pixels as the budget allows),
///     then the quality is raised again with the binary search to fill what is left.
/// The result is the probe with the most bytes among those that fit, so the file ends just below the target.
struct ImageFitSearch {
    struct Probe: Equatable, Sendable {
        var scale: Double
        var quality: Int
    }

    enum Result: Equatable, Sendable {
        case fit(Probe, bytes: Int)
        /// Nothing fits; `smallest` is the smallest size that was produced.
        case unreachable(smallest: Int)
    }

    /// Step of the resize ladder (20% per step).
    static let ladderRatio = 0.8
    /// Smallest long edge the search will go down to.
    static let minLongEdge = 48

    let targetBytes: Int
    let minQuality: Int
    let maxQuality: Int
    let allowResize: Bool
    let longEdge: Int
    /// Quality used while the size is being searched by scale.
    let resizeQuality: Int

    private enum State {
        case start, tryMax
        case qSearch(scale: Double, lo: Int, hi: Int)
        case ladder(k: Int)
        case refine(high: Double, low: Double, iteration: Int)
        case qFill(scale: Double, lo: Int, hi: Int)
        case lastResort(scale: Double)
        case done
    }

    private var state = State.start
    private var pending: Probe?
    private(set) var best: (probe: Probe, bytes: Int)?
    private(set) var smallest = Int.max
    private(set) var result: Result?
    /// Number of probes asked so far (tests assert the search stays short).
    private(set) var probeCount = 0

    init(targetBytes: Int, minQuality: Int, maxQuality: Int = 100, allowResize: Bool, longEdge: Int) {
        self.targetBytes = max(targetBytes, 1)
        self.maxQuality = min(max(maxQuality, 1), 100)
        self.minQuality = min(max(minQuality, 1), self.maxQuality)
        self.allowResize = allowResize
        self.longEdge = max(longEdge, 1)
        self.resizeQuality = min(self.maxQuality, max(self.minQuality, 75))
    }

    /// Scale of ladder step `k` (k = 0 is the full size).
    static func ladderScale(_ k: Int) -> Double { pow(ladderRatio, Double(k)) }

    /// The next probe to encode, or nil when the search is finished (`result` is set).
    mutating func next() -> Probe? {
        guard result == nil else { return nil }
        let p: Probe
        switch state {
        case .start: p = Probe(scale: 1, quality: minQuality)
        case .tryMax: p = Probe(scale: 1, quality: maxQuality)
        case .qSearch(let s, let lo, let hi): p = Probe(scale: s, quality: (lo + hi) / 2)
        case .ladder(let k): p = Probe(scale: Self.ladderScale(k), quality: resizeQuality)
        case .refine(let high, let low, _): p = Probe(scale: (high + low) / 2, quality: resizeQuality)
        case .qFill(let s, let lo, let hi): p = Probe(scale: s, quality: (lo + hi) / 2)
        case .lastResort(let s): p = Probe(scale: s, quality: minQuality)
        case .done: return nil
        }
        pending = p
        probeCount += 1
        return p
    }

    /// Reports the encoded size of the probe returned by the last `next()`.
    mutating func record(bytes: Int) {
        guard let p = pending else { return }
        pending = nil
        smallest = min(smallest, bytes)
        let fits = bytes <= targetBytes
        if fits, best == nil || bytes > best!.bytes { best = (p, bytes) }
        switch state {
        case .start:
            if fits {
                if minQuality == maxQuality { finishFit() } else { state = .tryMax }
            } else if allowResize, Double(longEdge) * Self.ladderScale(1) >= Double(Self.minLongEdge) { state = .ladder(k: 1) }
            else { finishUnreachable() }
        case .tryMax:
            if fits { finishFit() } else { advanceQuality(scale: 1, lo: minQuality, hi: maxQuality, fill: false) }
        case .qSearch(let s, let lo, let hi):
            let mid = (lo + hi) / 2
            advanceQuality(scale: s, lo: fits ? mid : lo, hi: fits ? hi : mid, fill: false)
        case .ladder(let k):
            if fits {
                state = .refine(high: Self.ladderScale(k - 1), low: Self.ladderScale(k), iteration: 0)
            } else if Double(longEdge) * Self.ladderScale(k + 1) >= Double(Self.minLongEdge) {
                state = .ladder(k: k + 1)
            } else if minQuality < resizeQuality {
                state = .lastResort(scale: Self.ladderScale(k))
            } else {
                finishUnreachable()
            }
        case .refine(let high, let low, let it):
            let mid = (high + low) / 2
            let nHigh = fits ? high : mid, nLow = fits ? mid : low
            if it + 1 >= 4 || nHigh / nLow < 1.02 {
                advanceQuality(scale: nLow, lo: resizeQuality, hi: maxQuality + 1, fill: true)
            } else {
                state = .refine(high: nHigh, low: nLow, iteration: it + 1)
            }
        case .qFill(let s, let lo, let hi):
            let mid = (lo + hi) / 2
            advanceQuality(scale: s, lo: fits ? mid : lo, hi: fits ? hi : mid, fill: true)
        case .lastResort:
            if fits { finishFit() } else { finishUnreachable() }
        case .done:
            break
        }
    }

    private mutating func advanceQuality(scale: Double, lo: Int, hi: Int, fill: Bool) {
        if hi - lo <= 1 { finishFit() } else { state = fill ? .qFill(scale: scale, lo: lo, hi: hi) : .qSearch(scale: scale, lo: lo, hi: hi) }
    }

    private mutating func finishFit() {
        state = .done
        if let b = best { result = .fit(b.probe, bytes: b.bytes) } else { result = .unreachable(smallest: smallest) }
    }

    private mutating func finishUnreachable() {
        state = .done
        result = .unreachable(smallest: smallest == Int.max ? 0 : smallest)
    }
}

extension ImageFit {
    /// Binary search over quality (lossy formats) to the largest quality whose file is <= target; if even the lowest acceptable quality is too big,
    /// halve the long edge in steps and search again. `encode` returns the encoded bytes for (image, quality 1...100); the search is pure and testable.
    ///
    /// Throws a calm "too small" message when nothing fits (the smallest result is reported), never returns a file over the target.
    static func search(image: CGImage, targetBytes: Int64, minQuality: Int = 30, allowResize: Bool,
                       encode: (CGImage, Int) throws -> Data) throws -> (data: Data, quality: Int, scale: Double) {
        var search = ImageFitSearch(targetBytes: Int(clamping: targetBytes), minQuality: minQuality, allowResize: allowResize, longEdge: max(image.width, image.height))
        var bestData: Data?
        var cache: (scale: Double, image: CGImage)?
        while let probe = search.next() {
            let scaled: CGImage
            if let c = cache, c.scale == probe.scale { scaled = c.image }
            else { scaled = probe.scale >= 0.999 ? image : resize(image, scale: probe.scale); cache = (probe.scale, scaled) }
            let data = try encode(scaled, probe.quality)
            search.record(bytes: data.count)
            if let b = search.best, b.probe == probe { bestData = data }
        }
        switch search.result {
        case .fit(let probe, _):
            guard let data = bestData else { throw ConversionError.noOutput }
            return (data, probe.quality, probe.scale)
        case .unreachable(let smallest):
            throw FitMessages.tooSmall(kind: .image, smallest: Int64(smallest), target: targetBytes)
        case .none:
            throw ConversionError.noOutput
        }
    }

    /// Scales `image` by `scale` (high-quality interpolation), keeping its colour space when it is an RGB / gray one.
    static func resize(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        return draw(image, width: w, height: h, flattenOnWhite: false) ?? image
    }

    /// Redraws `image` at a new size; `flattenOnWhite` removes transparency (JPEG / HEIC have none).
    static func draw(_ image: CGImage, width: Int, height: Int, flattenOnWhite: Bool) -> CGImage? {
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb { space = cs } else { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = (flattenOnWhite ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return nil }
        ctx.interpolationQuality = .high
        if flattenOnWhite { ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
