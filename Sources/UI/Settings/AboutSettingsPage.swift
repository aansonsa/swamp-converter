import SwiftUI

/// Settings > About when the app module has not registered its own About page: the wordmark, the version and a button that opens the About window.
/// The app module replaces this page by registering `.about` (the registry keeps the last registration).
struct AboutSettingsPage: View {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        case let (_, b?): return b
        default: return L("development build", "сборка для разработки")
        }
    }

    var body: some View {
        EmptyStateView(symbol: "circle.hexagongrid", title: "Swamp Converter",
                       message: L("Version \(Self.versionText). Convert, compress and tidy files from a wheel that opens where you drag them. Works on macOS 26 or later.",
                                  "Версия \(Self.versionText). Конвертируйте, сжимайте и приводите в порядок файлы с колеса, которое открывается там, куда вы их тащите. Работает на macOS 26 и новее."),
                       showsWordmark: true) {
            Button(L("About Swamp Converter", "О Swamp Converter")) { AboutWindowController.shared.show() }
        }
        .appRoot()
    }
}
