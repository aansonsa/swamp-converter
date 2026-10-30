import AppKit

enum MenuBarIcon {
    /// A black-and-clear template image: the "swp" letters of the logo (`BrandArtwork.swpLetters`, from `swamp-logo.psd`), 70 percent of `pointSize` tall so the tall p
    /// keeps clear of the menu bar's edges. macOS tints it for light, dark and highlighted menu bars. Checked at 18 pt on both menu bars by the `app.menubar-icon` snapshot.
    @MainActor static func templateImage(pointSize: CGFloat) -> NSImage {
        // The decoded letters themselves, given a point size: AppKit scales the 1096 px original when it draws. Images redrawn into a new bitmap lost the template
        // tint (they stayed black on a dark menu bar), this one keeps it. The status item centres it in the bar.
        let height = (pointSize * 0.7).rounded()
        let image = (BrandArtwork.swpLetters.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: (height * BrandArtwork.swpAspect).rounded(.up), height: height)
        image.isTemplate = true
        image.accessibilityDescription = "Swamp Converter"
        return image
    }
}

/// What the badge on the status item shows. Pink only ever appears here, small, and only while something happens (the glyph itself stays a monochrome template).
enum MenuBarBadgeState: Equatable {
    case none
    /// Jobs run, progress unknown: a small solid dot.
    case busy
    /// Jobs run with a known fraction (0...1): a ring that fills.
    case progress(Double)
    /// The last batch failed and the person has not looked yet: a small diamond (a shape, not only a colour).
    case error

    static func from(fraction: Double?, running: Int, waiting: Int, hasUnseenError: Bool) -> MenuBarBadgeState {
        if running + waiting > 0 {
            if let f = fraction, f.isFinite { return .progress(min(max(f, 0), 1)) }
            return .busy
        }
        return hasUnseenError ? .error : .none
    }
}

/// The badge: two layers, no timers, no animation (implicit Core Animation actions are off, so Reduce Motion is respected by construction). It sits in the top-right corner of the
/// status item button and is redrawn only when the model publishes (at most 10 Hz).
final class MenuBarBadgeView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private(set) var state: MenuBarBadgeState = .none
    static let diameter: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        for l in [track, fill] { l.actions = ["path": NSNull(), "strokeEnd": NSNull(), "hidden": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()] }
        setAccessibilityElement(false)
        apply(.none)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static var pink: CGColor { Brand.pinkRGB.nsColor.cgColor }

    override func layout() {
        super.layout()
        apply(state)
    }

    func apply(_ new: MenuBarBadgeState) {
        state = new
        let d = Self.diameter
        let box = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        isHidden = new == .none
        switch new {
        case .none:
            track.isHidden = true; fill.isHidden = true
        case .busy:
            track.isHidden = true
            fill.isHidden = false
            fill.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
            fill.fillColor = Self.pink; fill.strokeColor = nil; fill.strokeEnd = 1
        case .progress(let f):
            let ring = box.insetBy(dx: 1, dy: 1)
            // A mid-grey track reads on light and dark menu bars alike.
            track.isHidden = false
            track.path = CGPath(ellipseIn: ring, transform: nil)
            track.fillColor = nil; track.strokeColor = CGColor(gray: 0.5, alpha: 0.55); track.lineWidth = 1.5
            fill.isHidden = false
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * max(f, 0.04), clockwise: true)
            fill.path = arc
            fill.fillColor = nil; fill.strokeColor = Self.pink; fill.lineWidth = 2; fill.lineCap = .round; fill.strokeEnd = 1
        case .error:
            track.isHidden = true
            fill.isHidden = false
            var t = CGAffineTransform(translationX: box.midX, y: box.midY).rotated(by: .pi / 4)
            fill.path = CGPath(roundedRect: CGRect(x: -2.6, y: -2.6, width: 5.2, height: 5.2), cornerWidth: 1, cornerHeight: 1, transform: &t)
            fill.fillColor = Self.pink; fill.strokeColor = nil; fill.strokeEnd = 1
        }
    }
}
