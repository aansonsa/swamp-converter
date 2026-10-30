import SwiftUI

/// The four first-run pages. Native layout (title, body, one card), a single pink call to action, glass only on the small illustration and the card. Everything is bilingual and wraps.
struct OnboardingView: View {
    static let size = CGSize(width: 560, height: 520)

    @ObservedObject var model: OnboardingModel
    var settings: SettingsData = AppSettings.shared.data
    var tools: () -> [OnboardingToolRow]
    @State private var toolRows: [OnboardingToolRow] = []
    @StateObject private var setup = SetupChecklistModel()
    @Environment(\.a11y) private var a11y

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.Space.md) {
                hero
                Text(title.text).font(DS.Typo.title).multilineTextAlignment(.center)
                Text(subtitle.text).font(DS.Typo.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                card
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(model.page)
            .transition(.opacity)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DS.Surface.window)
        .animation(DS.Motion.animation(DS.Motion.open, reduceMotion: a11y.reduceMotion), value: model.page)
        .onAppear { if toolRows.isEmpty { toolRows = tools() } }
    }

    // MARK: Pages

    private var title: L10n {
        switch model.page {
        case .wheel: return L10n("Drag a file, get a wheel", "Перетащите файл, и появится колесо")
        case .hotkeys: return L10n("Or press a shortcut", "Или нажмите сочетание клавиш")
        case .permissions: return L10n("Switch on what you want", "Включите то, что нужно")
        case .tools: return L10n("Works on its own, better with a few tools", "Работает сразу, а с парой программ ещё лучше")
        }
    }

    private var subtitle: L10n {
        switch model.page {
        case .wheel: return L10n("Start dragging any file, then tap a key or shake it. Drop it on a sector and the conversion starts.",
                                 "Начните перетаскивать любой файл, затем нажмите клавишу или встряхните его. Отпустите на секторе, и преобразование начнётся.")
        case .hotkeys: return L10n("The shortcut opens the wheel for what you are looking at: the files selected in Finder or the page open in your browser.",
                                   "Сочетание открывает колесо для того, на что вы смотрите: файлы, выделенные в Finder, или страница в браузере.")
        case .permissions: return L10n("Nothing is asked until you press a button, and you can skip all of it: dragging files onto the wheel works right away.",
                                       "Ничего не спрашивается, пока вы не нажмёте кнопку, и всё это можно пропустить: перетаскивание файлов на колесо работает сразу.")
        case .tools: return L10n("Images, PDF, text and most audio work with macOS alone. These optional programs add more; Swamp Converter never installs anything by itself.",
                                 "Изображения, PDF, текст и большинство аудио работают средствами macOS. Эти необязательные программы добавляют возможностей; Swamp Converter ничего не устанавливает сам.")
        }
    }

    @ViewBuilder private var hero: some View {
        switch model.page {
        case .wheel: Brand.wordmark(size: 52).padding(.vertical, DS.Space.xs)
        case .hotkeys: heroSymbol("keyboard")
        case .permissions: heroSymbol("checkmark.shield")
        case .tools: heroSymbol("wrench.and.screwdriver")
        }
    }

    private func heroSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: DS.symbolWeight))
            .foregroundStyle(.primary)
            .frame(width: 68, height: 68)
            .glassSurface(in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder private var card: some View {
        GlassPanel(cornerRadius: DS.Radius.card, padding: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                switch model.page {
                case .wheel: wheelRows
                case .hotkeys: hotkeyRows
                case .permissions: permissionRows
                case .tools: toolRowsView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wheelRows: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(OnboardingKeys.wheelKeys(settings), id: \.title.en) { entry in
                HStack(spacing: DS.Space.md) {
                    KeyCapView(keys: [entry.glyph]).frame(width: 36, alignment: .leading)
                    Text(entry.title.text).font(.callout.weight(.medium))
                    Text(entry.detail.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.md) {
                Image(systemName: "hand.draw").frame(width: 36, alignment: .leading).foregroundStyle(.secondary)
                Text(L("Shake the files", "Встряхните файлы")).font(.callout.weight(.medium))
                Text(L("works too", "тоже работает")).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var hotkeyRows: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // The chord that is really registered: on a Mac with several keyboard layouts macOS keeps Control-Option-Space for switching them, and the app takes the next free one.
            hotkeyRow(settings.hotkey, effective: HotkeyManager.shared.wheel?.effective, L("Open the wheel", "Открыть колесо"), L("Finder selection, browser page or clipboard picture", "Выделение в Finder, страница в браузере или картинка из буфера"))
            hotkeyRow(settings.downloadHotkey, effective: HotkeyManager.shared.download?.effective, L("Download this page", "Скачать эту страницу"), L("starts at once, no wheel", "начинается сразу, без колеса"))
            Divider()
            Text(L("Safari, Chrome and most other browsers share the page address by themselves. Dia and Firefox do not: select the link, or copy the address (Command-L, then Command-C), then press the shortcut.",
                   "Safari, Chrome и большинство других браузеров сами сообщают адрес страницы. Dia и Firefox нет: выделите ссылку или скопируйте адрес (Command-L, затем Command-C) и нажмите сочетание."))
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hotkeyRow(_ setting: HotkeySetting, effective: HotkeyCombo?, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            if setting.enabled { KeyCapView(effective ?? setting.combo) } else { Text(L("Off", "Выкл.")).font(.callout).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SetupChecklistRows(model: setup, kinds: [.automation, .selectedText, .loginItem])
            Divider()
            Label {
                Text(L("Notifications: macOS asks the first time a job finishes while the app is in the background. Nothing is requested now.",
                       "Уведомления: macOS спросит, когда задача впервые завершится, пока приложение в фоне. Сейчас ничего не запрашивается."))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "bell").foregroundStyle(.secondary) }
        }
    }

    private var toolRowsView: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(toolRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    StatusDot(row.found ? .done : .idle, size: 12).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Space.xs) {
                            Text(row.name).font(.callout.weight(.medium))
                            Text(row.found ? L("found", "найдено") : L("not installed", "не установлено")).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(row.purpose.text).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Space.md) {
            Button(L("Skip", "Пропустить")) { model.onFinish() }
                .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                .opacity(model.isLast ? 0 : 1).disabled(model.isLast)
            Spacer()
            HStack(spacing: DS.Space.sm) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { p in
                    Circle().fill(p == model.page ? Brand.pink : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(L("Page \(model.page.rawValue + 1) of \(OnboardingPage.allCases.count)", "Страница \(model.page.rawValue + 1) из \(OnboardingPage.allCases.count)")))
            Spacer()
            if model.isLast { Button(L("Tools…", "Инструменты…")) { model.openToolSettings() }.buttonStyle(.flatSecondary) }
            if !model.isFirst { Button(L("Back", "Назад")) { model.back() }.buttonStyle(.flatSecondary) }
            Button(model.isLast ? L("Done", "Готово") : L("Continue", "Далее")) { model.next() }
                .buttonStyle(.brandProminent).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.lg)
    }
}

/// The modifier keys of the wheel, from the settings (tested).
enum OnboardingKeys {
    struct Entry: Equatable { var glyph: String; var title: L10n; var detail: L10n }

    nonisolated static func glyph(_ key: ModifierKey) -> String? {
        switch key {
        case .shift: return "\u{21E7}"
        case .control: return "\u{2303}"
        case .option: return "\u{2325}"
        case .command: return "\u{2318}"
        case .none: return nil
        }
    }

    nonisolated static func wheelKeys(_ s: SettingsData) -> [Entry] {
        var out: [Entry] = []
        if let g = glyph(s.convertKey) { out.append(Entry(glyph: g, title: L10n("Convert", "Конвертировать"), detail: L10n("change the format", "сменить формат"))) }
        if let g = glyph(s.toolsKey) { out.append(Entry(glyph: g, title: L10n("Tools", "Инструменты"), detail: L10n("compress, trim, extract", "сжать, обрезать, извлечь"))) }
        if let g = glyph(s.actionsKey) { out.append(Entry(glyph: g, title: L10n("Actions", "Действия"), detail: L10n("copy, move, share", "копировать, переместить, поделиться"))) }
        return out
    }
}
