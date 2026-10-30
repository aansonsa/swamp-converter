import SwiftUI

/// The four meanings a message, badge or dot can carry. One table for the whole app: symbol, spoken name, and the ink colour.
///
/// The inks are text-grade on purpose (>= 4.5:1 on every light and dark material, >= 7:1 with Increase Contrast, checked by the
/// "shared/status inks" self-test), so the same colour works for a glyph, a dot and a word. They are deeper than the system's red / orange / green
/// in light mode and lighter in dark mode; `info` is Swamp Blue's ink, because blue is the brand's calm "information" colour.
/// Meaning never rests on colour alone: every tone has its own symbol shape and its own spoken name.
enum StatusTone: CaseIterable, Sendable {
    case info, success, warning, error

    init(_ severity: OptionSeverity) {
        switch severity {
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }

    init(_ severity: UserMessage.Severity) {
        switch severity {
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    /// What VoiceOver says before the message ("Warning, ...").
    var spokenName: L10n {
        switch self {
        case .info: return L10n("Note", "Примечание")
        case .success: return L10n("Done", "Готово")
        case .warning: return L10n("Warning", "Предупреждение")
        case .error: return L10n("Error", "Ошибка")
        }
    }

    /// The resolved ink for an appearance. Pure: the dynamic colour below and the contrast self-test both use it.
    func rgb(dark: Bool, increaseContrast ic: Bool) -> RGB8 {
        switch self {
        case .info:
            return BrandRole.blueInk.rgb(dark: dark, increaseContrast: ic)
        case .error:
            if dark { return ic ? RGB8(255, 195, 192) : RGB8(255, 135, 129) }
            return ic ? RGB8(140, 32, 26) : RGB8(178, 41, 34)
        case .warning:
            if dark { return ic ? RGB8(255, 197, 108) : RGB8(255, 159, 10) }
            return ic ? RGB8(102, 60, 0) : RGB8(140, 82, 0)
        case .success:
            if dark { return ic ? RGB8(131, 227, 155) : RGB8(48, 209, 88) }
            return ic ? RGB8(21, 80, 36) : RGB8(29, 109, 49)
        }
    }

    /// For SOLID shapes (dots, diamonds, triangles): >= 3:1 on every material, more vivid than the text-grade ink. Thin glyphs and words use `ink`.
    func fillRGB(dark: Bool, increaseContrast ic: Bool) -> RGB8 {
        if dark || ic { return rgb(dark: dark, increaseContrast: ic) }
        switch self {
        case .info: return BrandRole.blueFill.rgb(dark: false, increaseContrast: false)
        case .error: return RGB8(214, 52, 44)
        case .warning: return RGB8(185, 105, 0)
        case .success: return RGB8(36, 140, 62)
        }
    }

    var fill: Color {
        switch self {
        case .info: return Self.infoFill
        case .success: return Self.successFill
        case .warning: return Self.warningFill
        case .error: return Self.errorFill
        }
    }
    private static let infoFill = Brand.dynamicColor { StatusTone.info.fillRGB(dark: $0, increaseContrast: $1) }
    private static let successFill = Brand.dynamicColor { StatusTone.success.fillRGB(dark: $0, increaseContrast: $1) }
    private static let warningFill = Brand.dynamicColor { StatusTone.warning.fillRGB(dark: $0, increaseContrast: $1) }
    private static let errorFill = Brand.dynamicColor { StatusTone.error.fillRGB(dark: $0, increaseContrast: $1) }

    /// Glyph, dot and word colour (built once per tone: views read it on every body evaluation).
    var ink: Color {
        switch self {
        case .info: return Self.infoInk
        case .success: return Self.successInk
        case .warning: return Self.warningInk
        case .error: return Self.errorInk
        }
    }
    private static let infoInk = Brand.dynamicColor { StatusTone.info.rgb(dark: $0, increaseContrast: $1) }
    private static let successInk = Brand.dynamicColor { StatusTone.success.rgb(dark: $0, increaseContrast: $1) }
    private static let warningInk = Brand.dynamicColor { StatusTone.warning.rgb(dark: $0, increaseContrast: $1) }
    private static let errorInk = Brand.dynamicColor { StatusTone.error.rgb(dark: $0, increaseContrast: $1) }

    /// The faint wash behind an inline message (a tint over the material, never a solid block). Increase Contrast replaces it with an outline.
    func wash(increaseContrast: Bool) -> Color { increaseContrast ? .clear : ink.opacity(0.11) }
}
