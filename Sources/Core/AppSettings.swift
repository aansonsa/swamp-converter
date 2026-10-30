import Foundation
import Combine

// All persistent settings in ONE Codable document: ~/Library/Application Support/Swamp Converter/settings.json.
// Enums are stored by name; unknown fields are ignored; a missing or malformed field falls back to its default
// (decoding is tolerant per top-level key); the file is written atomically; a corrupt file starts from defaults.

enum AppearanceSetting: String, Codable, CaseIterable, Sendable { case system, dark, light }
enum ModifierKey: String, Codable, CaseIterable, Sendable { case none, shift, control, option, command }
enum NotificationMode: String, Codable, CaseIterable, Sendable { case background, always, off }
enum DensitySetting: String, Codable, CaseIterable, Sendable { case simple, advanced }

// HotkeySetting / HotkeyCombo live in Hotkeys.swift.

/// The five "quality" knobs of the original app; they feed the quick recipes of the matching operations.
struct QualitySettings: Codable, Equatable, Sendable {
    var jpegQuality = 90        // image.to.* lossy targets and edits
    var compressQuality = 70    // image.compress
    var pdfDpi = 300            // pdf -> images
    var videoCrf = 23           // H.264 conversions
    var compressVideoCrf = 28   // video.compress
}

/// How the wheel is summoned while files are being dragged (the wheel module reads these; Settings > Wheel edits them).
struct GestureSettings: Codable, Equatable, Sendable {
    /// Tap one of the three wheel modifier keys during a file drag.
    var modifierTap = true
    /// Shake the dragged files.
    var shake = true
    /// 0 (hard to trigger) ... 1 (easy).
    var shakeSensitivity = 0.5
    /// Hold Command while releasing over a sector to open Studio instead of running the quick recipe.
    var commandOpensStudio = true
    /// The hotkey wheel reads the Finder selection (needs the Automation permission, asked at first use).
    var hotkeyUsesFinderSelection = true
}

struct WatchRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var path: String
    var recipe: Recipe
    var enabled = true
    /// Set when the rule was created from a one-click template (WatchTemplates), so Settings can show it as such.
    var templateID: String? = nil
    var includeSubfolders = false
    /// nil = global output rules.
    var outputDir: String? = nil
}

struct StudioPrefs: Codable, Equatable, Sendable {
    /// target id -> preset id last used
    var lastPresetByTarget: [String: String] = [:]
    var densityByFamily: [String: DensitySetting] = [:]
    /// NSStringFromRect of the Studio window.
    var windowFrame: String? = nil
    var inspectorPage: [String: String] = [:]
    var showQueue = true
}

struct SettingsData: Codable, Equatable, Sendable {
    // General
    /// English unless the person chooses otherwise: the app ships in English only (the Russian strings stay in the code, a Russian macOS does not switch the app over).
    var language: LanguageSetting = .english
    var appearance: AppearanceSetting = .system
    var showMenuBarIcon = true
    var firstRunDone = false
    var onboardingDone = false
    var confirmQuitWithJobs = true
    /// Mirror of the Login Items state the user chose (SMAppService is the source of truth).
    var launchAtLogin = false
    /// The app opens at login out of the box: the first launch of an installed copy registers it once (`LoginItem.applyDefaultOnce`), later only the General toggle changes it.
    var loginItemDefaultApplied = false
    /// Keep a Dock icon (and Cmd-Tab entry) while the Studio window is open.
    var showDockIconWithStudio = true
    /// Opt-in completion sound (never the only signal).
    var completionSound = false

    // Output
    var output = OutputRules()
    var revealResult = false
    var incomingFolder: String? = nil
    var lastCopyFolder: String? = nil
    var lastMoveFolder: String? = nil

    // Wheel and gestures
    var convertKey: ModifierKey = .shift
    var toolsKey: ModifierKey = .control
    var actionsKey: ModifierKey = .option
    /// Opens the wheel for the Finder selection / the browser page / the clipboard. Default Control-Option-Space; the wheel module
    /// falls back to a free preset when macOS owns the chord (see HotkeyPolicy).
    var hotkey = HotkeySetting()
    /// Skips the wheel and downloads the current browser page with `downloader.defaultMode`. Default Control-Option-D.
    var downloadHotkey = HotkeySetting.downloadDefault
    /// The hotkey wheel looks at the front browser (selected text, then the active tab, then the clipboard) for a link.
    var hotkeyReadsBrowser = true
    var gestures = GestureSettings()
    var gesturesPaused = false
    /// 0.8 ... 1.2
    var wheelScale: Double = 1.0
    var hapticsEnabled = true
    var wheelDwellMilliseconds = 250

    // Recipes
    var quality = QualitySettings()
    /// operation id -> user edits of its quick recipe (sparse option overrides)
    var quickRecipes: [String: OptionValues] = [:]
    var lastRecipe: Recipe? = nil
    var watchRules: [WatchRule] = []
    /// Global "share-safe" switch: every quick and automatic run removes location and camera metadata where the format allows it
    /// (`Operation.privacyOverrides`). Studio runs only follow it when the field was left at its default.
    var alwaysStripMetadata = false
    /// The hotkey wheel offers an image on the clipboard (convert / compress / remove background / save as).
    var offerClipboardImage = true

    // Downloader (the only part of the app that touches the network, and only after explicit consent)
    var downloader = DownloaderSettings()

    // Queue
    var maxConcurrentJobs = 2
    /// Watched-folder and chain jobs wait while the Mac runs on battery.
    var pauseBackgroundOnBattery = false
    /// Warn / refuse before a job starts when the estimated output does not fit on the disk.
    var freeSpaceGuard = true
    var notificationMode: NotificationMode = .background

    // Tools
    /// Tool.rawValue -> absolute path chosen by the user ("Locate...").
    var toolPaths: [String: String] = [:]

    // Actions
    var terminalApp: String? = nil
    var shelfPersist = false

    // Studio
    var studio = StudioPrefs()
}

final class AppSettings: ObservableObject, @unchecked Sendable {
    /// The app-wide instance. In --self-test the support folder is isolated BEFORE this is first touched.
    static let shared = AppSettings(fileURL: nil, isShared: true)

    @Published private(set) var revision = 0
    private let lock = NSLock()
    private var _data = SettingsData()
    private let fileURL: URL
    private let isShared: Bool
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "app.swampconverter.settings-save")
    private var autosave: Bool

    /// Thread-safe snapshot.
    var data: SettingsData { lock.lock(); defer { lock.unlock() }; return _data }

    /// `fileURL` nil = the standard file in Application Support (resolved NOW). Tests pass their own file and `autosave: false`.
    init(fileURL: URL?, autosave: Bool = true, isShared: Bool = false) {
        self.fileURL = fileURL ?? AppPaths.settingsFile
        self.autosave = autosave
        self.isShared = isShared
        reload()
    }

    /// Re-reads the file (tolerant). Missing / corrupt -> defaults.
    func reload() {
        let loaded: SettingsData
        if let bytes = try? Data(contentsOf: fileURL) { loaded = Self.decode(bytes) } else { loaded = SettingsData() }
        lock.lock(); _data = loaded; lock.unlock()
        applySideEffects()
        publish()
    }

    /// Mutates the settings atomically from any thread, publishes the change on the main thread and schedules a save.
    func update(_ change: (inout SettingsData) -> Void) {
        lock.lock()
        let before = _data
        change(&_data)
        let changed = _data != before
        lock.unlock()
        guard changed else { return }
        applySideEffects()
        publish()
        scheduleSave()
    }

    func resetToDefaults() { update { $0 = SettingsData() } }

    /// Writes immediately and atomically.
    func save() {
        saveWork?.cancel()
        let snapshot = data
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        guard autosave else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func publish() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    private func applySideEffects() {
        guard isShared else { return }
        let d = data
        Loc.shared.set(d.language)
        ToolLocator.shared.setUserOverrides(d.toolPaths)
    }

    /// Tolerant decoding: starts from defaults and accepts each top-level key only if the whole document still decodes.
    static func decode(_ bytes: Data) -> SettingsData {
        guard let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return SettingsData() }
        let enc = JSONEncoder()
        guard let defBytes = try? enc.encode(SettingsData()),
              var merged = (try? JSONSerialization.jsonObject(with: defBytes)) as? [String: Any] else { return SettingsData() }
        let dec = JSONDecoder()
        for (k, v) in obj {
            var trial = merged
            trial[k] = v
            guard let tb = try? JSONSerialization.data(withJSONObject: trial), (try? dec.decode(SettingsData.self, from: tb)) != nil else { continue }
            merged = trial
        }
        guard let fb = try? JSONSerialization.data(withJSONObject: merged), let result = try? dec.decode(SettingsData.self, from: fb) else { return SettingsData() }
        return result
    }
}
