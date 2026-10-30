import Foundation
import CoreGraphics

// The geometry and time maths behind the preview pane. Pure functions on plain values: the divider of the before / after image, zoom and pan, the loupe, the timeline
// (time <-> x, snapping, In / Out), crop handles and the safe-area overlays. Views only draw what these return, so the rules are testable without a window.

enum PreviewZoom: Equatable, Sendable { case fit, actual }

enum PreviewMath {
    // MARK: Before / after divider

    /// Fraction 0...1 of the divider for a pointer at `x` inside a view that starts at `minX` and is `width` wide.
    static func dividerFraction(x: CGFloat, minX: CGFloat = 0, width: CGFloat) -> Double {
        guard width > 1 else { return 0.5 }
        return Double(min(max((x - minX) / width, 0), 1))
    }

    /// Arrow keys move the divider by `step`; it never leaves the image.
    static func nudged(_ fraction: Double, by step: Double) -> Double { min(max(fraction + step, 0), 1) }

    // MARK: Placement and zoom

    /// The largest rect with the image's aspect ratio inside `container`, centred. `maxUpscale` stops tiny images from being blown up into mush.
    static func fitRect(image: CGSize, in container: CGSize, maxUpscale: CGFloat = 4) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height, maxUpscale)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// "100%": one image pixel is one device pixel, so the displayed size in points is `pixels / backingScale`. `pan` moves the image; it is clamped so the picture never
    /// leaves a gap on a side where it is larger than the container.
    static func actualRect(image: CGSize, in container: CGSize, backingScale: CGFloat, pan: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, backingScale > 0 else { return .zero }
        let size = CGSize(width: image.width / backingScale, height: image.height / backingScale)
        let p = clampedPan(pan, displayed: size, container: container)
        return CGRect(x: (container.width - size.width) / 2 + p.width, y: (container.height - size.height) / 2 + p.height, width: size.width, height: size.height)
    }

    static func clampedPan(_ pan: CGSize, displayed: CGSize, container: CGSize) -> CGSize {
        let maxX = max(0, (displayed.width - container.width) / 2), maxY = max(0, (displayed.height - container.height) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    /// Scale shown in the zoom chip: displayed points over image pixels, as percent of device pixels ("38%").
    static func zoomPercent(displayed: CGSize, image: CGSize, backingScale: CGFloat) -> Int {
        guard image.width > 0 else { return 100 }
        return Int((displayed.width * backingScale / image.width * 100).rounded())
    }

    // MARK: Loupe

    /// The region of the image (in pixels) a loupe at `point` (image pixel coordinates) magnifies, `side` pixels square, moved inward at the edges so it never leaves the image.
    static func loupeRect(center point: CGPoint, side: CGFloat, image: CGSize) -> CGRect {
        let s = min(side, image.width, image.height)
        guard s > 0 else { return .zero }
        let x = min(max(point.x - s / 2, 0), image.width - s), y = min(max(point.y - s / 2, 0), image.height - s)
        return CGRect(x: x.rounded(), y: y.rounded(), width: s.rounded(), height: s.rounded())
    }

    /// Converts a point inside the displayed rect to image pixel coordinates (top-left origin); nil outside it.
    static func imagePoint(viewPoint p: CGPoint, displayed: CGRect, image: CGSize) -> CGPoint? {
        guard displayed.width > 0, displayed.height > 0, displayed.contains(p) else { return nil }
        return CGPoint(x: (p.x - displayed.minX) / displayed.width * image.width, y: (p.y - displayed.minY) / displayed.height * image.height)
    }

    // MARK: Size delta chip

    /// Signed change in percent: negative = smaller. nil when the original size is unknown or zero.
    static func sizeDeltaPercent(original: Int64?, result: Int64?) -> Double? {
        guard let original, let result, original > 0 else { return nil }
        return (Double(result) - Double(original)) / Double(original) * 100
    }

    /// "-68%" / "+12%" with a real minus sign, "same size" within half a percent.
    static func sizeDeltaText(percent: Double) -> String {
        let r = Int(percent.rounded())
        if abs(percent) < 0.5 { return L("same size", "тот же размер") }
        return (r < 0 ? "\u{2212}" : "+") + Loc.percent(abs(r))
    }

    // MARK: Timeline

    static func time(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    static func x(forTime t: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(t / duration, 0), 1)) * width
    }

    /// Snaps to a whole frame of a clip that runs at `fps`; without a frame rate it rounds to milliseconds.
    static func snappedToFrame(_ t: Double, fps: Double?) -> Double {
        guard let fps, fps > 0, fps < 1000 else { return (t * 1000).rounded() / 1000 }
        return (t * fps).rounded() / fps
    }

    /// One keyboard step: a frame when the rate is known, else a tenth of a second; `coarse` (Shift) jumps a second.
    static func step(_ t: Double, forward: Bool, fps: Double?, coarse: Bool, duration: Double) -> Double {
        let delta = coarse ? 1.0 : (fps.flatMap { $0 > 0 ? 1 / $0 : nil } ?? 0.1)
        return min(max(snappedToFrame(t + (forward ? delta : -delta), fps: fps), 0), max(duration, 0))
    }

    /// Where a click on the track puts In / Out. Returns the new (start, end?) pair: the end is nil when it is the end of the clip (the schema's "until the end").
    static func settingIn(at t: Double, currentEnd: Double?, duration: Double, minGap: Double = 0.1) -> (start: Double, end: Double?) {
        let start = min(max(t, 0), max(duration - minGap, 0))
        if let e = currentEnd, e < start + minGap { return (start, nil) }
        return (start, currentEnd)
    }

    static func settingOut(at t: Double, currentStart: Double, duration: Double, minGap: Double = 0.1) -> (start: Double, end: Double?) {
        let end = min(max(t, 0), duration)
        if end >= duration - 0.0005 { return (currentStart, nil) }
        if end < currentStart + minGap { return (max(end - minGap, 0), end) }
        return (currentStart, end)
    }

    /// The kept range as a fraction of the track, for drawing the dimmed outside.
    static func keptFractions(start: Double, end: Double?, duration: Double) -> (lo: Double, hi: Double) {
        guard duration > 0 else { return (0, 1) }
        return (min(max(start / duration, 0), 1), min(max((end ?? duration) / duration, 0), 1))
    }

    // MARK: Crop handles

    /// Each edge as a fraction of the picture that is cut away.
    struct CropInsets: Equatable, Sendable {
        var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
        var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    }
    enum CropEdge: Sendable { case left, top, right, bottom }

    /// Drags one edge to the fraction `f` (distance from that edge of the picture); at least `minKept` of each side stays.
    static func moved(_ insets: CropInsets, edge: CropEdge, to f: Double, minKept: Double = 0.1) -> CropInsets {
        var i = insets
        let v = max(f, 0)
        switch edge {
        case .left: i.left = min(v, 1 - i.right - minKept)
        case .right: i.right = min(v, 1 - i.left - minKept)
        case .top: i.top = min(v, 1 - i.bottom - minKept)
        case .bottom: i.bottom = min(v, 1 - i.top - minKept)
        }
        return i
    }

    /// Pixel amounts cut from each edge, rounded down to even numbers (chroma subsampling) and never larger than the picture allows.
    static func cropPixels(_ insets: CropInsets, source: CGSize) -> (left: Int, top: Int, right: Int, bottom: Int) {
        func even(_ f: Double, _ total: Double) -> Int { max(0, Int(f * total) / 2 * 2) }
        return (even(insets.left, source.width), even(insets.top, source.height), even(insets.right, source.width), even(insets.bottom, source.height))
    }

    static func insets(leftPx: Int, topPx: Int, rightPx: Int, bottomPx: Int, source: CGSize) -> CropInsets {
        guard source.width > 0, source.height > 0 else { return CropInsets() }
        return CropInsets(left: Double(leftPx) / source.width, top: Double(topPx) / source.height, right: Double(rightPx) / source.width, bottom: Double(bottomPx) / source.height)
    }

    // MARK: Safe areas

    /// Where an app's own interface covers a vertical video (fractions of height / width). Drawn as a quiet overlay for vertical presets.
    struct SafeArea: Equatable, Sendable {
        var name: L10n
        var top: Double
        var bottom: Double
        var side: Double
    }
    static let verticalSafeAreas: [SafeArea] = [
        SafeArea(name: L10n("Stories and Reels", "Stories и Reels"), top: 0.13, bottom: 0.20, side: 0.06),
        SafeArea(name: L10n("Shorts and TikTok", "Shorts и TikTok"), top: 0.10, bottom: 0.22, side: 0.10)
    ]

    /// Safe areas matter only for tall pictures.
    static func offersSafeAreas(for size: CGSize) -> Bool { size.height > 0 && size.width / size.height < 0.7 }

    static func safeRect(_ a: SafeArea, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + rect.width * a.side, y: rect.minY + rect.height * a.top,
               width: rect.width * (1 - 2 * a.side), height: rect.height * (1 - a.top - a.bottom))
    }
}

// MARK: - Which schema fields the preview can drive

/// The pane writes In / Out, crop edges and the page range into the options. It finds the fields by key; a schema without them simply gets no handles.
struct PreviewBindings: Equatable, Sendable {
    var trimStartKey: String?
    var trimEndKey: String?
    var videoCrop: Bool
    var imageCrop: Bool
    var pageRangeKey: String?
    var ocrKey: String?
    var archiveMembersKey: String?
    var subtitleEncodingKey: String?
    var sheetDelimiterKey: String?
    var sheetEncodingKey: String?

    static let none = PreviewBindings(trimStartKey: nil, trimEndKey: nil, videoCrop: false, imageCrop: false, pageRangeKey: nil, ocrKey: nil, archiveMembersKey: nil,
                                      subtitleEncodingKey: nil, sheetDelimiterKey: nil, sheetEncodingKey: nil)

    var hasTrim: Bool { trimStartKey != nil && trimEndKey != nil }

    /// Keys come from the engines' schemas (stable dotted keys, also the JSON keys of presets).
    static func discover(in schema: OptionSchema?) -> PreviewBindings {
        guard let schema else { return .none }
        func has(_ k: String) -> Bool { schema.field(k) != nil }
        var b = PreviewBindings.none
        for (s, e) in [("t.start", "t.end"), ("aud.t.start", "aud.t.end")] where has(s) && has(e) { b.trimStartKey = s; b.trimEndKey = e; break }
        b.videoCrop = ["crop.mode", "crop.t", "crop.b", "crop.l", "crop.r"].allSatisfy(has)
        b.imageCrop = ["img.crop.mode", "img.crop.x", "img.crop.y", "img.crop.w", "img.crop.h"].allSatisfy(has)
        if has("pdf.pages") { b.pageRangeKey = "pdf.pages" }
        if has("pdf.ocr") { b.ocrKey = "pdf.ocr" }
        if has("arc.extract.members") { b.archiveMembersKey = "arc.extract.members" }
        if has("subs.enc.in") { b.subtitleEncodingKey = "subs.enc.in" }
        if has("sheet.delim") { b.sheetDelimiterKey = "sheet.delim" }
        if has("sheet.enc.in") { b.sheetEncodingKey = "sheet.enc.in" }
        return b
    }
}
