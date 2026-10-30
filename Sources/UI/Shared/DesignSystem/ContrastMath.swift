import Foundation

/// WCAG 2.x relative luminance and contrast ratio. Pure; used by the brand contrast self-test and available to any module that
/// wants to verify a colour pair at runtime (e.g. the wheel checks its label colour on the hovered sector).
enum ContrastMath {
    static func linear(_ channel: Int) -> Double {
        let c = Double(channel) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ c: RGB8) -> Double { 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }

    static func ratio(_ a: RGB8, _ b: RGB8) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` drawn at `alpha` over `bg` (what a tinted chip fill or a wash really looks like on a material).
    static func blend(_ fg: RGB8, alpha: Double, over bg: RGB8) -> RGB8 { bg.mixed(with: fg, alpha) }

    /// The smallest contrast ratio of `color` against any of `backgrounds`.
    static func worstRatio(_ color: RGB8, against backgrounds: [RGB8]) -> Double { backgrounds.map { ratio(color, $0) }.min() ?? 21 }

    /// Representative material colours the brand has to read on: from white to the mid-grey of a vibrancy sidebar in light mode,
    /// and from black to the lifted grey of an elevated dark material.
    static let lightMaterials = [RGB8(255, 255, 255), RGB8(246, 246, 246), RGB8(236, 236, 236), RGB8(230, 230, 230)]
    static let darkMaterials = [RGB8(0, 0, 0), RGB8(30, 30, 30), RGB8(44, 44, 46), RGB8(58, 58, 60)]
}
