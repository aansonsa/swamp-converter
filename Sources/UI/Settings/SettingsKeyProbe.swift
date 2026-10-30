import SwiftUI

// Proves that a settings key has a control. Every control that edits a `SettingsData` field is tagged with `.settingsKey("language")` (nested fields use the dotted form
// "gestures.shake"). Tagging costs nothing at run time (one nil check when a view appears). The self-test hosts each page in an offscreen window, installs a probe, and compares
// the keys that really appeared with `SettingsKeyTable`: a key in the table whose control is missing from the page fails the test.

final class SettingsKeyProbe: @unchecked Sendable {
    /// The probe that is collecting right now (tests only); nil in the app.
    nonisolated(unsafe) static var active: SettingsKeyProbe?

    private let lock = NSLock()
    private var found = Set<String>()

    func record(_ key: String) { lock.lock(); found.insert(key); lock.unlock() }
    var keys: Set<String> { lock.lock(); defer { lock.unlock() }; return found }
}

private struct SettingsKeyTag: ViewModifier {
    var key: String
    func body(content: Content) -> some View {
        content.onAppear { SettingsKeyProbe.active?.record(key) }
    }
}

extension View {
    /// Marks this control as the editor of one settings key (see `SettingsKeyTable`).
    func settingsKey(_ key: String) -> some View { modifier(SettingsKeyTag(key: key)) }
}

extension SettingsKeyTable {
    /// Parents whose children are listed in a nested table.
    static let parents: Set<String> = ["gestures", "output", "quality"]

    /// The keys a page must show, as the probe records them: top-level keys without nested children, plus the nested ones in dotted form.
    static func expectedKeys(for page: SettingsPageID) -> Set<String> {
        var out = Set<String>()
        for (k, e) in top where e.owner == page && !parents.contains(k) { out.insert(k) }
        for (k, e) in gestures where e.owner == page { out.insert("gestures.\(k)") }
        for (k, e) in output where e.owner == page { out.insert("output.\(k)") }
        for (k, e) in quality where e.owner == page { out.insert("quality.\(k)") }
        return out
    }
}
