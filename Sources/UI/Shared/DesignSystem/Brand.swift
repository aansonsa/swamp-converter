import SwiftUI
import AppKit

// THE ONE PLACE where the brand colours exist. Every module uses these tokens, never raw hex values.
//
// Apple's design language is the FOUNDATION (Liquid Glass, system materials and neutrals, SF Pro, SF Symbols, native controls,
// automatic light and dark). The brand is a SIGNATURE: small details only. Never fill windows, sidebars, cards or the wheel body.
//
//   Swamp Pink #FF72D9 (255,114,217)  the hot accent   -> app tint, hover/selected sector ring, drop-target glow, progress fills
//   Swamp Blue #7DA7D9 (125,167,217)  the calm secondary -> info chips, "quick recipe / default" markers, file-kind chips,
//                                                           secondary progress tracks, preview scrubbers, link-ish affordances
//
// Contrast: both are LIGHT colours. Use them for fills, strokes and glyphs on materials; for TEXT and thin icons use `pinkInk` /
// `blueInk` (deeper in light mode, the pure colour in dark mode where it already pops). The numbers are checked by the
// "shared/brand contrast" self-test: text >= 4.5:1 and graphics >= 3:1 against light and dark materials, text >= 7:1 with
// Increase Contrast.

struct RGB8: Equatable, Hashable, Sendable {
    var r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    /// Linear blend towards `other` by `t` (0...1).
    func mixed(with other: RGB8, _ t: Double) -> RGB8 {
        RGB8(Int((Double(r) + (Double(other.r) - Double(r)) * t).rounded()), Int((Double(g) + (Double(other.g) - Double(g)) * t).rounded()),
             Int((Double(b) + (Double(other.b) - Double(b)) * t).rounded()))
    }
}

enum BrandRole: CaseIterable, Sendable {
    case pink, blue, pinkInk, blueInk, onPink, onBlue
    /// The app tint (toggles on, slider fill, focus, selected segment, tinted buttons): pure pink in dark mode, a deepened Swamp Pink in light mode
    /// so tinted controls and system-drawn tinted text keep >= 3:1 on light materials (white labels on it: 3.8:1).
    case tint
    /// Text and glyphs INSIDE a tinted chip / badge (the capsule fill is the brand colour at about 14 percent): a touch deeper (light) or lighter (dark)
    /// than the plain ink so the text keeps >= 4.5:1 on the fill over the worst material. With Increase Contrast the chips drop the fill and use the plain ink.
    case pinkChip, blueChip
    /// Swamp Blue as a meaning-carrying graphic (secondary progress fill, preview scrubber): >= 3:1 against its track in light mode.
    case blueFill

    /// The resolved colour for an appearance. Pure: used by the dynamic colours below and by the contrast self-test.
    func rgb(dark: Bool, increaseContrast: Bool) -> RGB8 {
        switch self {
        case .pink: return Brand.pinkRGB
        case .blue: return Brand.blueRGB
        case .pinkInk:
            if dark { return increaseContrast ? Brand.pinkRGB.mixed(with: RGB8(255, 255, 255), 0.5) : Brand.pinkRGB }
            return increaseContrast ? RGB8(143, 0, 104) : RGB8(193, 0, 141)
        case .blueInk:
            if dark { return increaseContrast ? Brand.blueRGB.mixed(with: RGB8(255, 255, 255), 0.5) : Brand.blueRGB }
            return increaseContrast ? RGB8(36, 75, 123) : RGB8(49, 103, 168)
        case .pinkChip:
            if increaseContrast { return BrandRole.pinkInk.rgb(dark: dark, increaseContrast: true) }
            return dark ? RGB8(255, 149, 226) : RGB8(174, 0, 127)
        case .blueChip:
            if increaseContrast { return BrandRole.blueInk.rgb(dark: dark, increaseContrast: true) }
            return dark ? RGB8(158, 189, 226) : RGB8(44, 93, 151)
        case .blueFill:
            if dark { return increaseContrast ? Brand.blueRGB.mixed(with: RGB8(255, 255, 255), 0.25) : Brand.blueRGB }
            return increaseContrast ? RGB8(44, 93, 151) : RGB8(80, 130, 192)
        case .tint:
            if dark { return increaseContrast ? Brand.pinkRGB.mixed(with: RGB8(255, 255, 255), 0.25) : Brand.pinkRGB }
            return increaseContrast ? RGB8(193, 0, 141) : RGB8(246, 0, 180)
        case .onPink: return RGB8(36, 10, 28)      // label colour ON a pink fill (7.9:1)
        case .onBlue: return RGB8(10, 22, 38)      // label colour ON a blue fill
        }
    }
}

enum Brand {
    // The sampled logo colours.
    static let pinkRGB = RGB8(255, 114, 217)
    static let blueRGB = RGB8(125, 167, 217)

    /// The italic lean / baseline tilt of the logo in degrees. Used for the wordmark tilt and for small badges.
    static let slant: Double = 6
    /// Slant of the leading edge of progress fills (3 x the logo slant so it stays visible on a 6 pt bar).
    static let edgeSlant: Double = 18

    // Dynamic colours: they follow light / dark and Increase Contrast at draw time.
    static let pink: Color = dynamic(.pink)
    static let blue: Color = dynamic(.blue)
    /// Text and thin icons in the pink family.
    static let pinkInk: Color = dynamic(.pinkInk)
    /// Text and thin icons in the blue family.
    static let blueInk: Color = dynamic(.blueInk)
    /// Label colour for text drawn on a pink fill.
    static let onPink: Color = dynamic(.onPink)
    static let onBlue: Color = dynamic(.onBlue)

    /// Increase Contrast as the views see it. `.appRoot()` keeps it equal to the system flag; the snapshot harness forces it per variant so the
    /// Increase Contrast snapshots show the deeper inks too. Main-thread state (written from view bodies, read while drawing).
    nonisolated(unsafe) static var contrastOverride: Bool?

    static var increaseContrast: Bool { contrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// A colour that is resolved for the drawing appearance (light / dark) and for Increase Contrast every time it is drawn.
    static func dynamicColor(_ resolve: @escaping @Sendable (_ dark: Bool, _ increaseContrast: Bool) -> RGB8) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolve(dark, Brand.increaseContrast).nsColor
        })
    }

    private static func dynamic(_ role: BrandRole) -> Color { dynamicColor { role.rgb(dark: $0, increaseContrast: $1) } }

    /// The tint of the whole app (toggles on, slider fill, focus, selected tab / segment): appearance-aware so it keeps the contrast the system assumes.
    /// Decorative fills the app draws itself (progress bars, the hover ring) use the pure `pink`.
    static let tint: Color = dynamic(.tint)
    /// `tint` for AppKit drawing (rings, layer borders): resolves for the drawing appearance every time, like the SwiftUI colour.
    static let tintNSColor: NSColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return BrandRole.tint.rgb(dark: dark, increaseContrast: Brand.increaseContrast).nsColor
    }
    /// Text inside a tinted chip / badge (see `BrandRole.pinkChip`).
    static let pinkChipInk: Color = dynamic(.pinkChip)
    static let blueChipInk: Color = dynamic(.blueChip)
    /// Swamp Blue where it carries meaning as a graphic (secondary progress fill, scrubber).
    static let blueFill: Color = dynamic(.blueFill)

    // MARK: Wordmark

    /// The "swp" letters of the owner's logo, exactly as drawn in `swamp-logo.psd` (`BrandArtwork.swpLetters`, a template tinted with `color`); they already lean
    /// the way the logo does. `size` keeps the meaning it had when this was set in type: the letters stand 0.9 x `size` tall and 2.5 times as wide.
    /// Use sparingly: About, first run, empty states, the Studio header.
    @MainActor static func wordmark(size: CGFloat, color: Color = Brand.pink) -> some View {
        let height = (size * 0.9).rounded()
        return Image(nsImage: BrandArtwork.swpLetters)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: (height * BrandArtwork.swpAspect).rounded(), height: height)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Applies the brand tint. Every root view gets it (via `.appRoot()`).
    func brandTint() -> some View { tint(Brand.tint) }
}
