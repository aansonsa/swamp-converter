import SwiftUI
import AppKit

/// "What is switched on and what is not", in one place, for people who do not want to dig through Settings. The same model feeds the third page of the first-run tour and the
/// "Setup" section at the top of Settings > General. Reading the state never asks macOS for anything (`ask: false`, `AXIsProcessTrusted()`); only a button does.

/// One line of the checklist.
struct SetupItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case shortcut, automation, selectedText, loginItem, tools }
    /// `needed`: the wheel shortcut cannot do its job without it. `recommended`: makes things easier, never nags once the section has collapsed.
    enum Status: Equatable { case done, needed, recommended }

    var kind: Kind
    var status: Status
    /// A live detail shown after the title (the real chord, "2 of 3 found").
    var detail: String?
    var id: String { kind.rawValue }

    var title: L10n {
        switch kind {
        case .shortcut: return L10n("Open the wheel with a shortcut", "Открывать колесо сочетанием клавиш")
        case .automation: return L10n("Let it see your browser and Finder", "Разрешить видеть браузер и Finder")
        case .selectedText: return L10n("Read a link you have selected", "Читать выделенную ссылку")
        case .loginItem: return L10n("Start with your Mac", "Запускать вместе с Mac")
        case .tools: return L10n("Extra tools for video and documents", "Дополнительные программы для видео и документов")
        }
    }

    var why: L10n {
        switch kind {
        case .shortcut:
            return L10n("Press it anywhere to open the wheel for the page, file or picture in front of you.",
                        "Нажмите его где угодно, и откроется колесо для страницы, файла или картинки перед вами.")
        case .automation:
            return L10n("macOS asks once, so the shortcut can read the open page in your browser and the files selected in Finder.",
                        "macOS спросит один раз, чтобы сочетание могло читать открытую страницу в браузере и файлы, выбранные в Finder.")
        case .selectedText:
            return L10n("The easy way in Dia and Firefox: select a link, press the shortcut. Optional.",
                        "Простой способ в Dia и Firefox: выделите ссылку и нажмите сочетание. Необязательно.")
        case .loginItem:
            return L10n("Keeps the wheel ready after a restart. You can turn it off any time.",
                        "Колесо готово сразу после перезагрузки. Выключить можно в любой момент.")
        case .tools:
            return L10n("ffmpeg handles video and audio, yt-dlp downloads from links, LibreOffice opens Office files. Images, PDF and text work without them.",
                        "ffmpeg работает с видео и звуком, yt-dlp скачивает по ссылкам, LibreOffice открывает файлы Office. Изображения, PDF и текст работают и без них.")
        }
    }

    /// The button shown while the item is not done.
    var actionTitle: L10n {
        switch kind {
        case .shortcut: return L10n("Shortcuts…", "Сочетания…")
        case .automation, .selectedText: return L10n("Allow Access…", "Разрешить доступ…")
        case .loginItem: return L10n("Turn On", "Включить")
        case .tools: return L10n("Tools…", "Программы…")
        }
    }
}

/// Everything the checklist looks at, as plain values (the live reader fills it; tests build it by hand).
struct SetupInputs: Equatable {
    var shortcutEnabled = true
    var shortcutChord: String?
    var finder: AppleScriptRunner.Consent = .notDetermined
    /// The consent of every running browser whose open tab the shortcut can read.
    var browsers: [AppleScriptRunner.Consent] = []
    var accessibilityTrusted = false
    var login: LoginItem.State = .disabled
    var toolsFound = 0
    var toolsTotal = 3
}

enum SetupChecklist {
    static func items(_ i: SetupInputs) -> [SetupItem] {
        let automationDone = i.finder == .granted && i.browsers.allSatisfy { $0 == .granted }
        let loginStatus: SetupItem.Status = i.login == .enabled ? .done : .recommended
        let rows = [
            SetupItem(kind: .shortcut, status: i.shortcutEnabled && i.shortcutChord != nil ? .done : .needed, detail: i.shortcutEnabled ? i.shortcutChord : nil),
            SetupItem(kind: .automation, status: automationDone ? .done : .needed, detail: nil),
            SetupItem(kind: .selectedText, status: i.accessibilityTrusted ? .done : .recommended, detail: nil),
            SetupItem(kind: .loginItem, status: loginStatus, detail: nil),
            SetupItem(kind: .tools, status: i.toolsFound >= i.toolsTotal ? .done : .recommended, detail: "\(i.toolsFound) / \(i.toolsTotal)"),
        ]
        // A copy that cannot register as a login item (not an installed .app) has nothing to offer on that row.
        return i.login == .unavailable ? rows.filter { $0.kind != .loginItem } : rows
    }

    static func needsAttention(_ items: [SetupItem]) -> Bool { items.contains { $0.status == .needed } }

    /// The real state of this Mac, read without ever prompting.
    @MainActor
    static func liveInputs() -> SetupInputs {
        var i = SetupInputs()
        i.shortcutEnabled = AppSettings.shared.data.hotkey.enabled
        i.shortcutChord = HotkeyManager.shared.wheel?.effective?.displayString
        i.finder = AppleScriptRunner.consentSync(bundleID: FinderSelectionReader.finderBundleID, ask: false)
        i.browsers = AutomationAccess.targets
            .filter { $0.browser != nil && !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
            .map { AppleScriptRunner.consentSync(bundleID: $0.bundleID, ask: false) }
        i.accessibilityTrusted = AccessibilityAccess.isTrusted()
        i.login = LoginItem.state
        let tools: [Tool] = [.ffmpeg, .ytdlp, .soffice]
        i.toolsTotal = tools.count
        i.toolsFound = tools.filter { ToolLocator.shared.has($0) }.count
        return i
    }
}

@MainActor
final class SetupChecklistModel: ObservableObject {
    @Published private(set) var items: [SetupItem] = []
    @Published var note: String?
    @Published private(set) var busy: SetupItem.Kind?

    var inputs: () -> SetupInputs = { SetupChecklist.liveInputs() }
    /// Replaceable in tests; the defaults do what the buttons say.
    var openShortcuts: () -> Void = { SettingsWindowController.shared.show(page: .shortcuts) }
    var openTools: () -> Void = { SettingsWindowController.shared.show(page: .tools) }
    var allowAutomation: () async -> String = { AutomationAccess.message(await AutomationAccess.requestAll()) }
    var allowSelectedText: () async -> Void = { _ = await AccessibilityAccess.requestAfterExplaining() }
    var turnOnLogin: () -> Void = {
        if LoginItem.state == .requiresApproval { SettingsLinks.open(SettingsLinks.loginItems) } else { try? LoginItem.set(enabled: true) }
    }

    init() { refresh() }

    var needsAttention: Bool { SetupChecklist.needsAttention(items) }

    func refresh() { items = SetupChecklist.items(inputs()) }

    func perform(_ kind: SetupItem.Kind) async {
        guard busy == nil else { return }
        busy = kind; note = nil
        switch kind {
        case .shortcut: openShortcuts()
        case .automation: note = await allowAutomation()
        case .selectedText: await allowSelectedText()
        case .loginItem: turnOnLogin()
        case .tools: openTools()
        }
        busy = nil
        refresh()
    }
}

/// The rows themselves, used by both the tour page and the Settings section.
struct SetupChecklistRows: View {
    @ObservedObject var model: SetupChecklistModel
    var kinds: [SetupItem.Kind] = SetupItem.Kind.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(model.items.filter { kinds.contains($0.kind) }) { item in
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    StatusDot(item.status == .done ? .done : .idle, size: 12).frame(width: 14).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Space.xs) {
                            Text(item.title.text).font(.callout.weight(.medium))
                            if let detail = item.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Text(item.why.text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.sm)
                    if item.status != .done {
                        Button(item.actionTitle.text) { Task { await model.perform(item.kind) } }
                            .controlSize(.small).disabled(model.busy != nil)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let note = model.note { InlineMessage(note, tone: .info) }
        }
        .onAppear { model.refresh() }
        // The switches are flipped in System Settings, so look again whenever the person comes back to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

/// The "Setup" section at the top of Settings > General. Open while something needed is missing; once the needed steps are done it folds into one line.
struct SetupChecklistSection: View {
    @StateObject private var model = SetupChecklistModel()
    @State private var expanded = false

    var body: some View {
        FormSection(L("Setup", "Настройка"), symbol: "checklist") {
            if model.needsAttention {
                SetupChecklistRows(model: model)
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    SetupChecklistRows(model: model).padding(.top, DS.Space.xs)
                } label: {
                    Label(L("Everything needed is set up", "Всё необходимое настроено"), systemImage: "checkmark.circle").font(.callout.weight(.medium))
                }
            }
        }
    }
}
