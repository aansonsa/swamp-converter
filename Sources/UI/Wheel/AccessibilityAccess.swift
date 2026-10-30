import AppKit
import ApplicationServices
import SwiftUI

/// The Accessibility permission, which lets the shortcut read a link the person has SELECTED in any app (`BrowserLinkReader.readSelectedText`). It is the first source the
/// shortcut tries and, for browsers that cannot share their open tab (Dia, Firefox), the only automatic one. Until this existed nothing in the app could ask for it: the
/// reader only ever checks `AXIsProcessTrusted()`, which never shows a dialog, so the feature stayed silently off for everybody.
///
/// Swamp Converter has no Info.plist usage string to customise here (unlike Automation's `NSAppleEventsUsageDescription`); the "why" lives in the sheet shown BEFORE the
/// system alert. macOS also ties this permission to the app's code signature, and this build is signed ad hoc (no paid Developer ID), so it can ask again after an update.
enum AccessibilityAccess {
    /// Replaceable in tests. The default reads the real state and never prompts.
    nonisolated(unsafe) static var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    /// Replaceable in tests. The default shows macOS's own "wants to control this computer" alert (which only offers to open System Settings).
    nonisolated(unsafe) static var prompt: () -> Bool = { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }

    /// The one place that ever asks. Called only from the button, after the explanation sheet.
    @MainActor
    @discardableResult
    static func requestAfterExplaining() async -> Bool {
        guard !isTrusted() else { return true }
        guard await WheelPermissionPrompt.shared.ask(.explainAccessibility) == .primary else { return false }
        return prompt()
    }
}

/// The row Settings > Shortcuts shows under the Automation one: a live status dot, "Allow Access…" while it is off, and "Open System Settings…".
struct AccessibilityAccessRow: View {
    var title: String
    var help: String?
    @State private var trusted = AccessibilityAccess.isTrusted()
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingsRow(title, help: help) {
                HStack(spacing: DS.Space.sm) {
                    if !trusted {
                        Button(L("Allow Access…", "Разрешить доступ…")) {
                            asking = true
                            Task { @MainActor in
                                _ = await AccessibilityAccess.requestAfterExplaining()
                                trusted = AccessibilityAccess.isTrusted()
                                asking = false
                            }
                        }
                        .disabled(asking)
                    }
                    Button(L("Open System Settings…", "Открыть Системные настройки…")) { SettingsLinks.open(SettingsLinks.accessibility) }
                }
                .controlSize(.small)
            }
            // The status sits under the row, not beside the buttons, so the two buttons keep their full labels (same layout as the Automation row).
            HStack(spacing: DS.Space.xs) {
                StatusDot(trusted ? .done : .idle, size: 12)
                Text(trusted ? L("Allowed.", "Разрешено.") : L("Not allowed yet.", "Пока не разрешено."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear { trusted = AccessibilityAccess.isTrusted() }
        // The switch is flipped in System Settings, so look again whenever the person comes back to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AccessibilityAccess.isTrusted() }
    }
}
