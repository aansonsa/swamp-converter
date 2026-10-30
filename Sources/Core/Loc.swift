import Foundation
import SwiftUI
import Combine

// Localisation. Every user-visible string in code is written as L("English", "Русский") (or an L10n value).
// The language setting (system / Russian / English) takes effect immediately: SwiftUI roots wrapped in
// `.localizedRoot()` rebuild when `Loc.shared.revision` changes.

enum LanguageSetting: String, Codable, CaseIterable, Sendable {
    case system, russian, english
}

enum AppLanguage: String, Sendable { case en, ru }

/// A string with both translations. Resolved lazily so a stored value follows later language changes.
struct L10n: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    var en: String
    var ru: String
    init(_ en: String, _ ru: String) { self.en = en; self.ru = ru }
    /// A string that is identical in both languages (format names, codec names, units).
    init(_ both: String) { self.en = both; self.ru = both }
    init(stringLiteral value: String) { self.en = value; self.ru = value }
    /// The string in the active UI language.
    var text: String { Loc.shared.pick(en, ru) }
    /// Replaces `{name}` placeholders in both languages.
    func replacing(_ values: [String: String]) -> L10n {
        var e = en, r = ru
        for (k, v) in values { e = e.replacingOccurrences(of: "{\(k)}", with: v); r = r.replacingOccurrences(of: "{\(k)}", with: v) }
        return L10n(e, r)
    }
}

/// Shorthand used throughout the code base: `Text(L("Cancel", "Отмена"))`.
func L(_ en: String, _ ru: String) -> String { Loc.shared.pick(en, ru) }

final class Loc: ObservableObject, @unchecked Sendable {
    static let shared = Loc()

    /// Bumped on every language change. SwiftUI roots use it as an identity to rebuild.
    @Published private(set) var revision: Int = 0

    private let lock = NSLock()
    private var _setting: LanguageSetting = .system
    private var _systemOverride: AppLanguage?

    var setting: LanguageSetting {
        lock.lock(); defer { lock.unlock() }
        return _setting
    }

    /// The language actually in use (system resolved).
    var language: AppLanguage {
        lock.lock(); let s = _setting; let o = _systemOverride; lock.unlock()
        switch s {
        case .russian: return .ru
        case .english: return .en
        case .system: return o ?? Loc.systemLanguage()
        }
    }

    /// Changes the language. Safe from any thread; publishes on the main thread.
    func set(_ setting: LanguageSetting) {
        lock.lock()
        let changed = _setting != setting
        _setting = setting
        lock.unlock()
        if changed { bump() }
    }

    /// For tests: pretend the OS language is `lang` while the setting is `.system`.
    func setSystemLanguageOverride(_ lang: AppLanguage?) {
        lock.lock(); _systemOverride = lang; lock.unlock()
        bump()
    }

    private func bump() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    func pick(_ en: String, _ ru: String) -> String { language == .ru ? ru : en }

    /// Russian OS UI language -> Russian, anything else -> English.
    static func systemLanguage() -> AppLanguage {
        let first = Locale.preferredLanguages.first ?? "en"
        return first.hasPrefix("ru") ? .ru : .en
    }

    var locale: Locale { Locale(identifier: language == .ru ? "ru_RU" : "en_US") }

    // MARK: Plurals (CLDR categories)

    enum RuPlural { case one, few, many }

    /// Russian plural category: 1, 21, 31 -> one; 2-4, 22-24 -> few; 0, 5-20, 25-30, 11-14 -> many.
    static func ruCategory(_ n: Int) -> RuPlural {
        let a = abs(n)
        if a % 100 >= 11 && a % 100 <= 14 { return .many }
        switch a % 10 {
        case 1: return .one
        case 2, 3, 4: return .few
        default: return .many
        }
    }

    /// Picks the right plural form for the active language. EN uses one/other, RU uses one/few/many.
    static func plural(_ n: Int, enOne: String, enOther: String, ruOne: String, ruFew: String, ruMany: String) -> String {
        if Loc.shared.language == .ru {
            switch ruCategory(n) { case .one: return ruOne; case .few: return ruFew; case .many: return ruMany }
        }
        return abs(n) == 1 ? enOne : enOther
    }

    /// "1 file", "5 files" / "1 файл", "2 файла", "5 файлов" (the number is included).
    static func files(_ n: Int) -> String {
        plural(n, enOne: "\(n) file", enOther: "\(n) files", ruOne: "\(n) файл", ruFew: "\(n) файла", ruMany: "\(n) файлов")
    }

    /// "1 item", "3 items" / "1 элемент", "2 элемента", "5 элементов".
    static func items(_ n: Int) -> String {
        plural(n, enOne: "\(n) item", enOther: "\(n) items", ruOne: "\(n) элемент", ruFew: "\(n) элемента", ruMany: "\(n) элементов")
    }

    /// "1 page", "3 pages" / "1 страница", "2 страницы", "5 страниц".
    static func pages(_ n: Int) -> String {
        plural(n, enOne: "\(n) page", enOther: "\(n) pages", ruOne: "\(n) страница", ruFew: "\(n) страницы", ruMany: "\(n) страниц")
    }

    /// "42%" / "42 %": English writes the sign right after the number, Russian keeps a space.
    static func percent(_ n: Int) -> String {
        Loc.shared.language == .ru ? "\(n) %" : "\(n)%"
    }
}

// MARK: SwiftUI integration

/// Wrap the root view of every window/panel so it rebuilds on language change and formats numbers/dates
/// with the right locale: `ContentView().localizedRoot()`.
struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var loc = Loc.shared
    private let content: Content
    init(_ content: Content) { self.content = content }
    var body: some View {
        content
            .environment(\.locale, loc.locale)
            .id(loc.revision)
    }
}

extension View {
    func localizedRoot() -> some View { LocalizedRoot(self) }
}
