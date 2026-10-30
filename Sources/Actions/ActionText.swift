import Foundation

/// Small bilingual helpers shared by the actions: plurals as an `L10n` pair (both languages at once, so a stored value follows a later language change).
enum ActionText {
    /// "1 item" / "5 items" and "1 элемент" / "2 элемента" / "5 элементов".
    static func items(_ n: Int) -> L10n {
        L10n(n == 1 ? "1 item" : "\(n) items", "\(n) " + ruForm(n, one: "элемент", few: "элемента", many: "элементов"))
    }

    /// "1 file" / "5 files" and Russian forms.
    static func files(_ n: Int) -> L10n {
        L10n(n == 1 ? "1 file" : "\(n) files", "\(n) " + ruForm(n, one: "файл", few: "файла", many: "файлов"))
    }

    /// The Russian form for `n` (CLDR one / few / many).
    static func ruForm(_ n: Int, one: String, few: String, many: String) -> String {
        switch Loc.ruCategory(n) { case .one: return one; case .few: return few; case .many: return many }
    }
}
