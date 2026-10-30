import CoreGraphics

/// An 8-bit sRGB colour with the handful of named values the picture code and the tests share.
struct RGBA: Equatable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255
    static let red = RGBA(r: 255, g: 0, b: 0)
    static let green = RGBA(r: 0, g: 200, b: 0)
    static let blue = RGBA(r: 0, g: 0, b: 255)
    static let yellow = RGBA(r: 255, g: 220, b: 0)
    static let orange = RGBA(r: 255, g: 140, b: 0)
    static let white = RGBA(r: 255, g: 255, b: 255)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    var cgColor: CGColor { CGColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: Double(a) / 255) }
}
