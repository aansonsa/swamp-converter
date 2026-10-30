import AppKit
import SwiftUI

/// "Allow Access…" in Settings: asks macOS for Automation consent for Finder and every running browser that shares its page address, so Swamp Converter appears in
/// System Settings > Privacy & Security > Automation. macOS lists an app there only after the app has asked, and until now the only way to ask was the first press of the
/// wheel shortcut while that app was in front. Pressing the button counts as having read the explanation, so the shortcut does not explain it again.
@MainActor
enum AutomationAccess {
    struct Target: Equatable { var name: String; var bundleID: String; var browser: BrowserKind? }

    struct Summary: Equatable {
        var allowed: [String] = []
        var refused: [String] = []
        /// Installed but not open: macOS can only ask about an app that is running.
        var notRunning: [String] = []
    }

    /// Finder, then the named browsers whose open tab the shortcut can read (Firefox cannot be asked: it has no address to share), then every OTHER browser
    /// Launch Services knows about on this Mac — so a browser Swamp Converter has no special-cased name for (Dia, Orion, Zen, Yandex, ...) still gets asked
    /// and still shows up in System Settings > Privacy & Security > Automation once the person presses the button.
    static var targets: [Target] {
        [Target(name: "Finder", bundleID: FinderSelectionReader.finderBundleID, browser: nil)]
            + BrowserKind.allCases.filter(\.exposesTabURL).map { Target(name: $0.displayName, bundleID: $0.bundleID, browser: $0) }
            + BrowserKind.installedOtherBrowsers().map { Target(name: $0.displayName, bundleID: $0.bundleID, browser: $0) }
    }

    static func requestAll() async -> Summary {
        var s = Summary()
        for t in targets {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) != nil
            guard installed else { continue }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).isEmpty else { s.notRunning.append(t.name); continue }
            switch await AppleScriptRunner.consent(for: t.bundleID, ask: true) {
            case .granted: s.allowed.append(t.name); markExplained(t)
            case .denied: s.refused.append(t.name); markExplained(t)
            case .targetNotRunning: s.notRunning.append(t.name)
            case .notDetermined, .failed: break
            }
        }
        return s
    }

    private static func markExplained(_ t: Target) {
        if let b = t.browser { BrowserLinkReader.shared.markExplained(b) } else { FinderSelectionReader.shared.markExplained() }
    }

    /// One plain sentence per group, for the note under the button.
    static func message(_ s: Summary) -> String {
        var parts: [String] = []
        if !s.allowed.isEmpty { parts.append(L("Allowed: \(s.allowed.joined(separator: ", ")).", "Разрешено: \(s.allowed.joined(separator: ", ")).")) }
        if !s.refused.isEmpty {
            parts.append(L("Turned off: \(s.refused.joined(separator: ", ")). Switch them on in System Settings > Privacy & Security > Automation.",
                           "Выключено: \(s.refused.joined(separator: ", ")). Включите в Системных настройках > Конфиденциальность и безопасность > Автоматизация."))
        }
        if !s.notRunning.isEmpty {
            parts.append(L("Not open now: \(s.notRunning.joined(separator: ", ")). Open them and press the button again, or just use the shortcut in them.",
                           "Сейчас не открыты: \(s.notRunning.joined(separator: ", ")). Откройте их и нажмите кнопку ещё раз или просто используйте сочетание в них."))
        }
        return parts.isEmpty ? L("Nothing to ask: no supported browser is installed.", "Спрашивать не о чем: поддерживаемых браузеров нет.") : parts.joined(separator: " ")
    }
}

/// The row both Settings pages show: "Allow Access…" asks macOS now, "Open System Settings…" shows the list, and the outcome appears below.
struct AutomationAccessRow: View {
    var title: String
    var help: String?
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingsRow(title, help: help) {
                HStack(spacing: DS.Space.sm) {
                    Button(L("Allow Access…", "Разрешить доступ…")) {
                        working = true
                        Task { @MainActor in
                            note = AutomationAccess.message(await AutomationAccess.requestAll())
                            working = false
                        }
                    }
                    .disabled(working)
                    Button(L("Open System Settings…", "Открыть Системные настройки…")) { BrowserLinkReader.openAutomationSettings() }
                }
                .controlSize(.small)
            }
            if let note { InlineMessage(note, tone: .info) }
        }
    }
}
