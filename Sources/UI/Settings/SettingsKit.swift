import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Shared plumbing of the Settings pages: bindings that always write through `settings.update { }` (no page keeps a private copy of a setting), the
// few system effects a setting needs at once (appearance), system deep links, open / save panels, a slider that commits when released, and the table that
// says which page owns which `SettingsData` key (a self-test walks the struct and refuses a key nobody owns).

extension AppSettings {
    /// A binding to one field of `SettingsData`. Reads the live value, writes through `update`, so several windows editing at once stay consistent.
    func binding<T>(_ keyPath: WritableKeyPath<SettingsData, T>) -> Binding<T> {
        Binding(get: { self.data[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// A binding that maps a stored value to the control's type (an optional folder path to a non-optional string, a percent to a fraction).
    func binding<T, U>(_ keyPath: WritableKeyPath<SettingsData, T>, get: @escaping (T) -> U, set: @escaping (U, T) -> T) -> Binding<U> {
        Binding(get: { get(self.data[keyPath: keyPath]) }, set: { value in self.update { $0[keyPath: keyPath] = set(value, $0[keyPath: keyPath]) } })
    }
}

/// The system effects of settings that are not read by anyone later (the rest is read by the module that owns the behaviour).
enum SettingsEffects {
    /// `NSApp.appearance` for the Appearance setting. System = nil (follow macOS).
    @MainActor
    static func applyAppearance(_ setting: AppearanceSetting) {
        guard let app = NSApp else { return }
        switch setting {
        case .system: app.appearance = nil
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        case .light: app.appearance = NSAppearance(named: .aqua)
        }
    }
}

/// Where the Settings window points people at System Settings. Deep links are best effort: a URL macOS does not know opens System Settings itself.
enum SettingsLinks {
    static let automation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Extension"
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let servicesShortcuts = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    @MainActor
    static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Open and save panels with the house defaults (no hidden files, sandbox-free, one answer).
@MainActor
enum SettingsPanels {
    static func chooseFolder(title: String, prompt: String? = nil, start: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = prompt ?? L("Choose", "Выбрать")
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        if let start { p.directoryURL = start }
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFile(title: String, types: [UTType]? = nil, start: URL? = nil, prompt: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = prompt ?? L("Choose", "Выбрать")
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        if let types { p.allowedContentTypes = types }
        if let start { p.directoryURL = start }
        return p.runModal() == .OK ? p.url : nil
    }

    static func saveFile(title: String, name: String, type: UTType) -> URL? {
        let p = NSSavePanel()
        p.title = title
        p.nameFieldStringValue = name
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    /// The `.swampreset` type (a JSON document with its own extension).
    static var presetType: UTType { UTType(filenameExtension: "swampreset", conformingTo: .json) ?? .json }
}

/// The size each pane asks for. A pane scrolls when its content is taller, so these are comfortable sizes, not limits. The window fits the pane (HIG);
/// a page that is not listed (the Downloader, About) gets the default.
enum SettingsPaneMetrics {
    static func size(for id: SettingsPageID) -> CGSize {
        switch id {
        case .general: return CGSize(width: 680, height: 700)
        case .wheel: return CGSize(width: 860, height: 700)
        case .shortcuts: return CGSize(width: 680, height: 640)
        case .recipes: return CGSize(width: 720, height: 700)
        case .folders: return CGSize(width: 760, height: 680)
        case .tools: return CGSize(width: 720, height: 700)
        case .downloader: return CGSize(width: 680, height: 680)
        case .about: return CGSize(width: 520, height: 480)
        default: return CGSize(width: 680, height: 600)
        }
    }

    /// The pane size limited to what the screen can show (the title bar and a margin are kept free).
    static func clamped(_ size: CGSize, visibleFrame: CGRect?) -> CGSize {
        guard let v = visibleFrame else { return size }
        return CGSize(width: min(size.width, max(v.width - 40, 520)), height: min(size.height, max(v.height - 120, 420)))
    }
}

/// A slider that shows its value while it moves and commits once, when released. Settings are written (and saved, and re-published to every window) once per gesture,
/// not once per pixel of mouse travel.
struct CommitSlider: View {
    var title: String
    var range: ClosedRange<Double>
    var step: Double
    @Binding var value: Double
    var minLabel: String?
    var maxLabel: String?
    @State private var draft: Double?

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, minLabel: String? = nil, maxLabel: String? = nil) {
        self.title = title; self._value = value; self.range = range; self.step = step; self.minLabel = minLabel; self.maxLabel = maxLabel
    }

    var body: some View {
        Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range, step: step) {
            Text(title)
        } minimumValueLabel: {
            if let minLabel { Text(minLabel).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        } maximumValueLabel: {
            if let maxLabel { Text(maxLabel).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        } onEditingChanged: { editing in
            if !editing, let d = draft { value = d; draft = nil }
        }
        .labelsHidden()
        .accessibilityLabel(Text(title))
        .frame(minWidth: 160)
    }
}

/// Which page shows which key. Every field of `SettingsData` (and of the structs inside it) appears exactly once, so a new setting cannot be added without deciding where a person
/// changes it. `nil` owner = the value is internal state or is edited somewhere else on purpose; the reason says where.
enum SettingsKeyTable {
    struct Entry {
        var owner: SettingsPageID?
        var note: String
    }

    static let top: [String: Entry] = [
        "language": Entry(owner: nil, note: "internal: the app ships in English only, so there is no language control (the stored value stays English)"),
        "appearance": Entry(owner: .general, note: "Appearance"),
        "showMenuBarIcon": Entry(owner: .general, note: "Menu-bar icon"),
        "firstRunDone": Entry(owner: nil, note: "internal: set by the first-run window"),
        "onboardingDone": Entry(owner: nil, note: "internal: set by the first-run window"),
        "confirmQuitWithJobs": Entry(owner: .general, note: "Confirm quit"),
        "launchAtLogin": Entry(owner: .general, note: "Launch at login (the Login Items state is the truth)"),
        "loginItemDefaultApplied": Entry(owner: nil, note: "internal: open at login was switched on once at first launch"),
        "showDockIconWithStudio": Entry(owner: .general, note: "Dock icon"),
        "completionSound": Entry(owner: .general, note: "Sound"),
        "output": Entry(owner: .general, note: "Output rules"),
        "revealResult": Entry(owner: .general, note: "Show in Finder when done"),
        "incomingFolder": Entry(owner: .general, note: "Incoming folder"),
        "lastCopyFolder": Entry(owner: nil, note: "internal: initial folder of the Copy picker"),
        "lastMoveFolder": Entry(owner: nil, note: "internal: initial folder of the Move picker"),
        "convertKey": Entry(owner: .wheel, note: "Modifier of the Convert wheel"),
        "toolsKey": Entry(owner: .wheel, note: "Modifier of the Tools wheel"),
        "actionsKey": Entry(owner: .wheel, note: "Modifier of the Actions wheel"),
        "hotkey": Entry(owner: .shortcuts, note: "Wheel hotkey"),
        "downloadHotkey": Entry(owner: .shortcuts, note: "Download hotkey"),
        "hotkeyReadsBrowser": Entry(owner: .shortcuts, note: "Read the browser"),
        "gestures": Entry(owner: .wheel, note: "Gestures (see the nested table)"),
        "gesturesPaused": Entry(owner: .wheel, note: "Pause gestures"),
        "wheelScale": Entry(owner: .wheel, note: "Wheel size"),
        "hapticsEnabled": Entry(owner: .wheel, note: "Haptics"),
        "wheelDwellMilliseconds": Entry(owner: .wheel, note: "Dwell"),
        "quality": Entry(owner: .recipes, note: "Quality knobs (see the nested table)"),
        "quickRecipes": Entry(owner: .recipes, note: "Quick recipes per operation"),
        "lastRecipe": Entry(owner: nil, note: "internal: Repeat last"),
        "watchRules": Entry(owner: .folders, note: "Watched folders"),
        "alwaysStripMetadata": Entry(owner: .general, note: "Share-safe"),
        "offerClipboardImage": Entry(owner: .general, note: "Offer the clipboard image"),
        "downloader": Entry(owner: .downloader, note: "Edited on the Downloader page (download-ui module)"),
        "maxConcurrentJobs": Entry(owner: .general, note: "Parallel jobs"),
        "pauseBackgroundOnBattery": Entry(owner: .general, note: "Pause background work on battery"),
        "freeSpaceGuard": Entry(owner: .general, note: "Free-space guard"),
        "notificationMode": Entry(owner: .general, note: "Notifications"),
        "toolPaths": Entry(owner: .tools, note: "Locate..."),
        "terminalApp": Entry(owner: .general, note: "Terminal app of the Actions wheel"),
        "shelfPersist": Entry(owner: .general, note: "Keep the shelf between launches"),
        "studio": Entry(owner: nil, note: "internal: window frame, density and last presets are remembered by the Studio itself")
    ]

    static let gestures: [String: Entry] = [
        "modifierTap": Entry(owner: .wheel, note: "Open with a modifier key"),
        "shake": Entry(owner: .wheel, note: "Open by shaking"),
        "shakeSensitivity": Entry(owner: .wheel, note: "Shake sensitivity"),
        "commandOpensStudio": Entry(owner: .wheel, note: "Command opens the Studio"),
        "hotkeyUsesFinderSelection": Entry(owner: .shortcuts, note: "Use the Finder selection")
    ]

    static let output: [String: Entry] = [
        "dirMode": Entry(owner: .general, note: "Where results go"),
        "subfolderName": Entry(owner: .general, note: "Subfolder name"),
        "customDir": Entry(owner: .general, note: "Chosen folder"),
        "nameTemplate": Entry(owner: .general, note: "Name template"),
        "collision": Entry(owner: .general, note: "When a file exists"),
        "keepDates": Entry(owner: .general, note: "Keep dates"),
        "trashSource": Entry(owner: nil, note: "Studio Output page only: a global switch that trashes originals would be a trap"),
        "verify": Entry(owner: nil, note: "Studio Output page only"),
        "after": Entry(owner: nil, note: "Studio Output page only; the quick path uses revealResult")
    ]

    static let quality: [String: Entry] = [
        "jpegQuality": Entry(owner: .recipes, note: "JPEG and WebP quality"),
        "compressQuality": Entry(owner: .recipes, note: "Compress quality"),
        "pdfDpi": Entry(owner: .recipes, note: "PDF resolution"),
        "videoCrf": Entry(owner: .recipes, note: "Video quality"),
        "compressVideoCrf": Entry(owner: .recipes, note: "Compressed video quality")
    ]

    /// The names of the stored properties of `value`, in declaration order.
    static func labels<T>(of value: T) -> [String] { Mirror(reflecting: value).children.compactMap(\.label) }
}
