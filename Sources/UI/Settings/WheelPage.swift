import SwiftUI

/// Pure rules of the three wheel keys: one modifier key opens one wheel, so choosing a key that another wheel uses swaps the two (nothing is silently doubled).
enum WheelKeyLogic {
    struct Keys: Equatable {
        var convert: ModifierKey
        var tools: ModifierKey
        var actions: ModifierKey

        subscript(wheel: WheelKind) -> ModifierKey {
            get { wheel == .convert ? convert : (wheel == .tools ? tools : actions) }
            set { switch wheel { case .convert: convert = newValue; case .tools: tools = newValue; default: actions = newValue } }
        }
    }

    /// `wheel` gets `key`; the wheel that had it gets the key `wheel` used to have. `.none` may be shared by any number of wheels.
    static func assign(_ key: ModifierKey, to wheel: WheelKind, in keys: Keys) -> Keys {
        guard WheelKind.fileWheels.contains(wheel), keys[wheel] != key else { return keys }
        var out = keys
        let old = keys[wheel]
        if key != .none, let other = WheelKind.fileWheels.first(where: { $0 != wheel && keys[$0] == key }) { out[other] = old }
        out[wheel] = key
        return out
    }
}

/// Settings > Wheel: how the wheel is summoned, how it feels, and which operations it holds (the layout editor).
struct WheelPage: View {
    @ObservedObject private var settings: AppSettings

    init(settings: AppSettings = .shared) { _settings = ObservedObject(wrappedValue: settings) }

    private var gestures: GestureSettings { settings.data.gestures }

    var body: some View {
        Form {
            summonSection
            feelSection
            FormSection(L("Layout", "Раскладка"), symbol: "circle.hexagongrid",
                        footer: L("Changes apply to the next wheel you open. A wheel shows up to 7 operations and 8 more behind “More…”; everything else stays in the Studio.",
                                  "Изменения применяются к следующему открытому колесу. На колесе помещается до 7 операций и ещё 8 за пунктом «Ещё…»; остальное доступно в Студии.")) {
                WheelLayoutEditor()
            }
        }
        .formStyle(.grouped)
        .appRoot()
    }

    // MARK: Summoning

    private var summonSection: some View {
        FormSection(L("Opening the wheel", "Открытие колеса"), symbol: "hand.draw",
                    footer: L("The wheel opens while you drag files. Pressing the wheel shortcut, dropping on the Dock icon or using Services opens it too (see Shortcuts).",
                              "Колесо открывается, пока вы тащите файлы. Его открывают и сочетание клавиш, перетаскивание на значок в Dock и Службы (см. «Сочетания клавиш»).")) {
            SettingsToggleRow(L("Pause", "Пауза"),
                              help: L("Stops the wheel from opening while you drag, and pauses watched folders. The shortcut, Services and the Dock icon keep working.",
                                      "Колесо не открывается при перетаскивании, отслеживаемые папки приостанавливаются. Сочетание клавиш, Службы и значок в Dock продолжают работать."),
                              isOn: settings.binding(\.gesturesPaused))
                .settingsKey("gesturesPaused")
            SettingsToggleRow(L("Open with a modifier key", "Открывать клавишей-модификатором"),
                              help: L("Tap one of the keys below while dragging files to open that wheel.", "Нажмите одну из клавиш ниже во время перетаскивания, чтобы открыть нужное колесо."),
                              isOn: settings.binding(\.gestures.modifierTap)).settingsKey("gestures.modifierTap")
            keyRow(.convert, L("Convert wheel", "Колесо «Конвертация»"), "convertKey")
            keyRow(.tools, L("Tools wheel", "Колесо «Инструменты»"), "toolsKey")
            keyRow(.actions, L("Actions wheel", "Колесо «Действия»"), "actionsKey")
            SettingsToggleRow(L("Open by shaking", "Открывать встряхиванием"),
                              help: L("Shake the files you are dragging to open the Convert wheel.", "Встряхните перетаскиваемые файлы, чтобы открыть колесо «Конвертация»."),
                              isOn: settings.binding(\.gestures.shake)).settingsKey("gestures.shake")
            SettingsRow(L("Shake sensitivity", "Чувствительность встряхивания")) {
                CommitSlider(L("Shake sensitivity", "Чувствительность встряхивания"), value: settings.binding(\.gestures.shakeSensitivity), in: 0...1, step: 0.1,
                             minLabel: L("Hard", "Туго"), maxLabel: L("Easy", "Легко"))
                    .frame(maxWidth: 260)
                    .disabled(!gestures.shake)
            }.settingsKey("gestures.shakeSensitivity")
            SettingsToggleRow(L("Command opens the Studio", "Command открывает Студию"),
                              help: L("Hold Command while you release over an operation to choose its options in the Studio instead of running it.",
                                      "Удерживайте Command при отпускании над операцией, чтобы выбрать параметры в Студии, а не запускать её сразу."),
                              isOn: settings.binding(\.gestures.commandOpensStudio)).settingsKey("gestures.commandOpensStudio")
        }
    }

    private func keyRow(_ wheel: WheelKind, _ title: String, _ key: String) -> some View {
        SettingsRow(title, symbol: wheel.symbol) {
            SettingsMenuPicker(title, selection: keyBinding(wheel),
                               options: ModifierKey.allCases.map { ($0, SettingsLabels.modifier($0)) })
                .disabled(!gestures.modifierTap)
        }.settingsKey(key)
    }

    private func keyBinding(_ wheel: WheelKind) -> Binding<ModifierKey> {
        Binding(get: {
            let d = settings.data
            return WheelKeyLogic.Keys(convert: d.convertKey, tools: d.toolsKey, actions: d.actionsKey)[wheel]
        }, set: { key in
            settings.update { d in
                let next = WheelKeyLogic.assign(key, to: wheel, in: WheelKeyLogic.Keys(convert: d.convertKey, tools: d.toolsKey, actions: d.actionsKey))
                d.convertKey = next.convert; d.toolsKey = next.tools; d.actionsKey = next.actions
            }
        })
    }

    // MARK: Feel

    private var feelSection: some View {
        FormSection(L("Size and feel", "Размер и ощущения"), symbol: "slider.horizontal.below.square.and.square.filled") {
            SettingsRow(L("Wheel size", "Размер колеса")) {
                HStack(spacing: DS.Space.sm) {
                    CommitSlider(L("Wheel size", "Размер колеса"), value: settings.binding(\.wheelScale), in: 0.8...1.2, step: 0.05,
                                 minLabel: L("Smaller", "Меньше"), maxLabel: L("Larger", "Больше"))
                        .frame(maxWidth: 260)
                    Text(Loc.percent(Int((settings.data.wheelScale * 100).rounded()))).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                }
            }.settingsKey("wheelScale")
            SettingsRow(L("Pause before “More…” opens", "Пауза перед открытием «Ещё…»"),
                        help: L("How long the pointer rests on “More…” while dragging before the second ring appears.",
                                "Сколько указатель должен задержаться на «Ещё…» при перетаскивании, прежде чем появится второе кольцо.")) {
                HStack(spacing: DS.Space.sm) {
                    CommitSlider(L("Pause before More opens", "Пауза перед открытием «Ещё»"), value: dwellBinding, in: 100...600, step: 50,
                                 minLabel: L("Short", "Короткая"), maxLabel: L("Long", "Долгая"))
                        .frame(maxWidth: 260)
                    Text("\(settings.data.wheelDwellMilliseconds) " + L("ms", "мс")).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary).frame(minWidth: 58, alignment: .trailing)
                }
            }.settingsKey("wheelDwellMilliseconds")
            SettingsToggleRow(L("Haptic feedback", "Тактильный отклик"),
                              help: L("A light tap on the trackpad when the pointer moves onto an operation.", "Лёгкий отклик трекпада, когда указатель переходит на операцию."),
                              isOn: settings.binding(\.hapticsEnabled)).settingsKey("hapticsEnabled")
        }
    }

    private var dwellBinding: Binding<Double> {
        Binding(get: { Double(settings.data.wheelDwellMilliseconds) }, set: { v in settings.update { $0.wheelDwellMilliseconds = Int(v.rounded()) } })
    }
}
