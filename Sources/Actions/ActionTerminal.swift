import Foundation

// Which terminal "Terminal here" opens, and where. Pure functions so the mapping is tested without launching anything.

enum TerminalApps {
    struct Choice: Equatable {
        var name: String
        var bundleID: String?
        /// A chosen `.app` bundle (Settings may store a path for a terminal that is not in the list).
        var path: String?
    }

    static let terminal = Choice(name: "Terminal", bundleID: "com.apple.Terminal", path: nil)
    static let known: [Choice] = [
        terminal,
        Choice(name: "iTerm", bundleID: "com.googlecode.iterm2", path: nil),
        Choice(name: "Ghostty", bundleID: "com.mitchellh.ghostty", path: nil),
        Choice(name: "Warp", bundleID: "dev.warp.Warp-Stable", path: nil),
        Choice(name: "kitty", bundleID: "net.kovidgoyal.kitty", path: nil)
    ]

    /// `setting` is `AppSettings.terminalApp`: nil or empty = Terminal; a known name ("iTerm", "ghostty", "iTerm2"); a bundle identifier; or a path to an .app.
    static func choice(for setting: String?) -> Choice {
        let raw = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return terminal }
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".app", with: "")
        let aliases = ["terminal": "Terminal", "iterm": "iTerm", "iterm2": "iTerm", "ghostty": "Ghostty", "warp": "Warp", "kitty": "kitty"]
        if let name = aliases[key], let known = known.first(where: { $0.name == name }) { return known }
        if let known = known.first(where: { $0.bundleID?.lowercased() == raw.lowercased() }) { return known }
        if raw.hasPrefix("/") || raw.lowercased().hasSuffix(".app") {
            let name = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
            return Choice(name: name.isEmpty ? raw : name, bundleID: nil, path: raw)
        }
        if raw.contains(".") { return Choice(name: raw.split(separator: ".").last.map(String.init) ?? raw, bundleID: raw, path: nil) }
        return terminal
    }

    /// The first item if it is a folder, otherwise the folder it lives in.
    static func folder(for items: [FileItem]) -> URL? {
        guard let first = items.first else { return nil }
        return first.isDirectory ? first.url : first.parent
    }

    /// Where the chosen app is installed, or nil when it is not.
    @MainActor
    static func applicationURL(for choice: Choice, system: ActionsSystem) -> URL? {
        if let path = choice.path { return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
        return choice.bundleID.flatMap { system.applicationURL($0) }
    }
}

enum TerminalRunner {
    /// Opens the terminal at the item's folder. Falls back to Terminal.app, saying so, when the chosen terminal is not installed.
    @MainActor
    static func run(items: [FileItem], setting: String?, system: ActionsSystem? = nil) throws -> ActionResult {
        let system = system ?? ActionsSystem.current
        guard let folder = TerminalApps.folder(for: items), system.fs.isDirectory(folder) else {
            throw ConversionError.message(L10n("The folder is no longer there.", "Папки больше нет на прежнем месте."))
        }
        let choice = TerminalApps.choice(for: setting)
        var note: L10n?
        var app = TerminalApps.applicationURL(for: choice, system: system)
        if app == nil, choice != TerminalApps.terminal {
            app = TerminalApps.applicationURL(for: TerminalApps.terminal, system: system)
            note = L10n("\(choice.name) is not installed, so Terminal was used.", "\(choice.name) не установлен, поэтому открыт Терминал.")
        }
        guard let app else {
            throw ConversionError.message(L10n("No terminal app was found on this Mac.", "На этом Mac не найдено ни одной программы-терминала."))
        }
        system.openFolderInTerminal(folder, app)
        return ActionResult(note: note, outputs: [])
    }
}
