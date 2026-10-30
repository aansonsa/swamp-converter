import Foundation

/// The few words the shared components say themselves (accessibility labels, badge text). One list, so the "shared/microcopy" self-test can check every
/// string: both languages present, no exclamation marks, no three-dot ellipsis, no emoji. Calm, short, verb-first.
enum SharedStrings {
    static let modified = L10n("Modified", "Изменено")
    static let revertToDefault = L10n("Revert to default", "Вернуть значение по умолчанию")
    static let help = L10n("Help", "Справка")
    static let dismiss = L10n("Dismiss", "Скрыть")
    static let close = L10n("Close", "Закрыть")
    static let progress = L10n("Progress", "Прогресс")
    static let inProgress = L10n("in progress", "выполняется")
    static let space = L10n("Space", "Пробел")

    /// Every string above plus the spoken names of the tones and the status kinds.
    static var all: [L10n] {
        [modified, revertToDefault, help, dismiss, close, progress, inProgress, space]
            + StatusTone.allCases.map(\.spokenName) + StatusKind.allCases.map(\.spokenName)
    }

    /// "Key 200" / "Клавиша 200" for a key without a name.
    static func unnamedKey(_ code: UInt32) -> String { L("Key \(code)", "Клавиша \(code)") }
}
