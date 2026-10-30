import Foundation
import AppKit

/// The Finder selection for the hotkey. Order: Finder frontmost -> AppleScript `selection as alias list` (needs Automation consent for Finder, explained once, 150 ms budget,
/// background thread); then the clipboard's file URLs; no Accessibility / Input Monitoring / Full Disk Access is ever requested.
@MainActor
final class FinderSelectionReader {
    static let shared = FinderSelectionReader()

    enum Outcome: Sendable {
        case files([FileItem])
        case denied
        case empty
        case failed(String)
        /// The person has not been told yet why the Mac will ask to control Finder: show `FinderSelectionReader.explanation`, call `markExplained()`, read again.
        case needsExplanation
    }

    nonisolated static let finderBundleID = "com.apple.finder"
    /// The budget of a warm read (a large selection on a slow disk takes Finder well over 0.15 s). The very first Apple event of a session is slower still.
    static let warmBudget: TimeInterval = 1.0
    static let coldBudget: TimeInterval = 1.0

    nonisolated static let explanation = L10n(
        "Swamp Converter reads your Finder selection so the shortcut can convert the files you chose. macOS will ask you to allow this once.",
        "Swamp Converter считывает выбранные в Finder файлы, чтобы сочетание клавиш могло их преобразовать. macOS один раз попросит разрешения.")

    var runScript: (String, TimeInterval) async -> AppleScriptOutcome = { await AppleScriptRunner.run($0, timeout: $1) }
    var consentStatus: () -> AppleScriptRunner.Consent = { AppleScriptRunner.consentSync(bundleID: FinderSelectionReader.finderBundleID, ask: false) }
    var askConsent: () async -> AppleScriptRunner.Consent = { await AppleScriptRunner.consent(for: FinderSelectionReader.finderBundleID, ask: true) }

    private static let explainedKey = "app.swampconverter.wheel.finderExplained"
    private var hasReadOnce = false

    var isExplained: Bool { UserDefaults.standard.bool(forKey: Self.explainedKey) }
    func markExplained() { UserDefaults.standard.set(true, forKey: Self.explainedKey) }

    /// Compiles `BrowserScripts.finderSelectionScript()`, executes it on a background queue, parses the paths, drops duplicates and files that vanished, and builds
    /// the `FileItem`s off the main thread. Never raises the system dialog before our own explanation was shown.
    func read() async -> Outcome {
        switch consentStatus() {
        case .denied: return .denied
        case .notDetermined:
            guard isExplained else { return .needsExplanation }
            switch await askConsent() {
            case .granted: break
            case .denied: return .denied
            default: return .failed(L("Finder did not answer.", "Finder не ответил."))
            }
        default: break
        }
        let budget = hasReadOnce ? Self.warmBudget : Self.coldBudget
        switch await runScript(BrowserScripts.finderSelectionScript(), budget) {
        case .timedOut:
            return .failed(L("Finder did not answer in time.", "Finder не ответил вовремя."))
        case .failure(let number, let message):
            if number == AppleScriptOutcome.notPermitted { return .denied }
            return .failed(message.isEmpty ? L("Could not read the Finder selection.", "Не удалось прочитать выбор в Finder.") : message)
        case .text(let text):
            hasReadOnce = true
            let urls = BrowserScripts.parseFinderSelection(text)
            let items = await Task.detached(priority: .userInitiated) {
                urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { FileItem(url: $0) }
            }.value
            return items.isEmpty ? .empty : .files(items)
        }
    }
}
