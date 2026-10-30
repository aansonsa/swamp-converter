import SwiftUI
import AppKit

// Snapshot sheets, part 2: messages, indicators, forms, notices, thumbnails, glass.

struct MessagesSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                InlineMessage(L("Hardware encoding is fastest. The software encoder is slower but smaller.", "Аппаратное кодирование быстрее всего. Программное медленнее, но файл получается меньше."),
                              tone: .info, detail: L("Applies to H.264 and HEVC.", "Относится к H.264 и HEVC."))
                InlineMessage(L("Converted 5 files.", "Преобразовано файлов: 5."), tone: .success, onDismiss: {})
                InlineMessage(L("The target size is larger than the source, so compressing will not save anything.", "Целевой размер больше исходного, поэтому сжатие ничего не даст."),
                              severity: .warning, fixTitle: L("Keep the Original Size", "Оставить исходный размер"), onFix: {})
                InlineMessage(L("Couldn’t convert \u{201C}holiday.mov\u{201D}. The disk is full. Free up 1.2 GB, then choose Retry.",
                                "Не удалось преобразовать «holiday.mov»: на диске не хватает места. Освободите 1,2 ГБ и нажмите «Повторить»."),
                              severity: .error, fixTitle: L("Retry", "Повторить"), onFix: {}, onDismiss: {})
                Text(L("Narrow column", "Узкая колонка")).font(DS.Typo.caption).foregroundStyle(.secondary).padding(.top, DS.Space.xs)
                InlineMessage(L("Subtitles will be burned into the picture and cannot be turned off later.", "Субтитры будут вшиты в изображение, и отключить их потом не получится."),
                              severity: .warning, fixTitle: L("Keep Them as a Separate Track", "Оставить отдельной дорожкой"), onFix: {})
                    .frame(width: 300)
                Spacer(minLength: 0)
            }
        }
    }
}

struct IndicatorsSheet: View {
    private let wheel = HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.option)
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                row(L("Status dots", "Статусы")) {
                    FlowLayout(spacing: DS.Space.md, lineSpacing: DS.Space.sm) {
                        ForEach(StatusKind.allCases, id: \.self) { k in
                            HStack(spacing: DS.Space.xs) { StatusDot(k, size: 14); Text(k.spokenName.text).font(DS.Typo.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                row(L("Small", "Мелкие")) { ForEach(StatusKind.allCases, id: \.self) { StatusDot($0, size: 8) } }
                row(L("Progress rings", "Кольца")) {
                    ProgressRing(value: 0, size: 28, showsTrack: true)
                    ProgressRing(value: 0.25, size: 28)
                    ProgressRing(value: 0.6, size: 28)
                    ProgressRing(value: 1, size: 28)
                    ProgressRing(value: nil, size: 28)
                    ProgressRing(value: 1, size: 28, isError: true)
                    ProgressRing(value: 0.5, size: 18)
                    ProgressRing(value: 0.5, size: 14, lineWidth: 1.5)
                }
                row(L("Menu bar", "Строка меню")) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "circle.grid.2x2").foregroundStyle(.primary)
                        ProgressRing(value: 0.4, size: 18)
                    }
                    .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                }
                row(L("Badges and keys", "Бейджи и клавиши")) {
                    ModifiedBadge(); ModifiedBadge(onRevert: {}); KeyCapView(wheel); KeyCapView(HotkeySetting.downloadDefault.combo)
                }
                row(L("Help", "Справка")) {
                    HelpLabel(L("Constant quality", "Постоянное качество"), help: L("Lower values keep more detail and make bigger files.", "Меньшие значения сохраняют больше деталей и дают файлы побольше."))
                    HelpPopoverButton(L("A short explanation.", "Короткое пояснение."))
                }
                GlassPanel(cornerRadius: DS.Radius.card, padding: 0) {
                    HelpPopoverContent(title: L("Constant quality", "Постоянное качество"), help: L("Lower values keep more detail and make bigger files. Pick a value, not a bitrate: the encoder spends bits where the picture needs them.",
                                                                                                    "Меньшие значения сохраняют больше деталей и дают файлы побольше. Выберите значение, а не битрейт: кодировщик потратит биты там, где они нужны картинке."),
                                       learnMoreTitle: L("Learn more", "Подробнее"), onLearnMore: {})
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(DS.Typo.caption).foregroundStyle(.secondary)
            HStack(spacing: DS.Space.md) { content() }
        }
    }
}

struct FormsSheet: View {
    @State private var on = true
    @State private var off = false
    var body: some View {
        Form {
            FormSection(L("Output", "Вывод"), symbol: "folder", footer: L("Files are written next to the originals unless you choose a folder.", "Файлы сохраняются рядом с исходными, если вы не выберете другую папку.")) {
                SettingsToggleRow(L("Keep the original files", "Сохранять исходные файлы"), help: L("Nothing is deleted or overwritten.", "Ничего не удаляется и не перезаписывается."), symbol: "doc.on.doc", isOn: $on)
                SettingsToggleRow(L("Remove location and camera information from every result", "Удалять сведения о местоположении и камере из каждого результата"), symbol: "location.slash", isOn: $off)
                SettingsRow(L("Name template", "Шаблон имени")) { TextField("", text: .constant("{name} (compressed)")).frame(width: 150) }
            }
            FormSection(L("Naming and destination of the finished files after conversion", "Именование и расположение готовых файлов после завершения преобразования"), symbol: "text.badge.checkmark") {
                SettingsRow(L("Add the target format to the name", "Добавлять целевой формат к имени файла"), help: L("For example \u{201C}holiday (HEVC).mp4\u{201D}.", "Например, «holiday (HEVC).mp4».")) { Toggle("", isOn: .constant(true)).labelsHidden() }
            }
            FormSection(L("Estimate", "Оценка")) {
                ValueRow(L("Output size", "Размер результата"), value: L("About 412 MB (68% smaller)", "Около 412 МБ (меньше на 68 %)"), help: L("Measured on a sample of the file.", "Измерено по фрагменту файла."))
                ValueRow(L("Time", "Время"), value: "6:12")
                HelpLabelRow()
                FormFootnote(L("The estimate is updated when you change an option.", "Оценка обновляется при изменении параметров."))
            }
        }
        .formStyle(.grouped)
        .appRoot()
    }
}

private struct HelpLabelRow: View {
    var body: some View {
        SettingsRow(L("Encoder", "Кодировщик")) { Picker("", selection: .constant(0)) { Text("HEVC (VideoToolbox)").tag(0); Text("H.264").tag(1) }.labelsHidden().frame(width: 190) }
    }
}

struct NoticeSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                NoticeCard(NoticeCardContent(title: L("Downloading: Mountain bike trail", "Загрузка: Горная велотрасса"), message: "youtube.com · 3:41 · 1080p", tone: .info, symbol: "arrow.down.circle",
                                             progress: .determinate(0.42), primary: nil, secondary: NoticeAction(L("Cancel", "Отмена")) {}, onClose: {}))
                NoticeCard(NoticeCardContent(title: L("Converted 5 files", "Преобразовано файлов: 5"), tone: .success, primary: NoticeAction(L("Show in Finder", "Показать в Finder")) {}, onClose: {}))
                NoticeCard(NoticeCardContent(title: L("Couldn’t download this page", "Не удалось скачать эту страницу"),
                                             message: L("The site asks you to sign in. Use your Safari sign-in, then try again.", "Сайт просит войти в аккаунт. Используйте вход из Safari и повторите попытку."),
                                             tone: .error, primary: NoticeAction(L("Use Safari sign-in", "Войти через Safari")) {}, secondary: NoticeAction(L("Settings", "Настройки")) {}, onClose: {}))
                NoticeCard(NoticeCardContent(title: L("Nothing selected", "Ничего не выбрано"), tone: .warning))
                NoticeCard(NoticeCardContent(title: L("Preparing", "Подготовка"), tone: .info, symbol: "film", progress: .indeterminate))
                Spacer(minLength: 0)
            }
        }
    }
}

struct ThumbnailsSheet: View {
    static let fixtures: [URL] = {
        let fx = TestFixtures(label: "shared-snap")
        var urls: [URL] = []
        if let u = try? fx.png("landscape.png", width: 640, height: 400, pattern: .quadrants) { urls.append(u) }
        if let u = try? fx.png("portrait.png", width: 400, height: 640, pattern: .gradient) { urls.append(u) }
        if let u = try? fx.jpeg("noise.jpg", width: 300, height: 300, pattern: .noise(seed: 7)) { urls.append(u) }
        if let u = try? fx.pdf("document.pdf", pages: 1, text: { _ in "Swamp" }) { urls.append(u) }
        return urls
    }()

    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Text(L("Rows (40 pt, fill)", "Строки (40 pt, заполнение)")).font(DS.Typo.caption).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.md) {
                    ForEach(Array(Self.fixtures.enumerated()), id: \.offset) { _, u in ThumbnailView(url: u, size: 40) }
                    ThumbnailView(url: URL(fileURLWithPath: "/nonexistent/clip.mov"), kind: .video, size: 40)
                    ThumbnailView(url: URL(fileURLWithPath: "/nonexistent/song.mp3"), kind: .audio, size: 40)
                    ThumbnailView(url: URL(fileURLWithPath: "/nonexistent/archive.zip"), kind: .archive, size: 40)
                }
                Text(L("Preview (fit)", "Просмотр (вписать)")).font(DS.Typo.caption).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.md) {
                    if Self.fixtures.count > 1 {
                        ThumbnailView(url: Self.fixtures[0], width: 200, height: 120, fit: true)
                        ThumbnailView(url: Self.fixtures[1], width: 120, height: 120, fit: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ChipsSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                chips.frame(width: 260, alignment: .leading)
                Divider()
                chips.frame(width: 460, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    private var chips: some View {
        FlowLayout {
            KindChip(kind: .video)
            InfoChip("MP4", symbol: "shippingbox")
            InfoChip("HEVC Main 10", symbol: "film")
            InfoChip("3840 x 2160", symbol: "rectangle.dashed")
            InfoChip("23,976 fps")
            InfoChip(L("HDR10", "HDR10"), symbol: "sun.max")
            InfoChip(L("Quick recipe", "Быстрый рецепт"), emphasized: true)
            InfoChip(L("Maximum quality without re-encoding", "Максимальное качество без перекодирования"), symbol: "sparkles")
            InfoChip(L("2 audio tracks", "2 звуковые дорожки"), symbol: "waveform")
        }
    }
}

struct GlassSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(spacing: DS.Space.lg) {
                    GlassPanel { Text(L("Plain glass", "Обычное стекло")).font(DS.Typo.headline) }
                    GlassPanel(tint: Brand.pink) { Text(L("Drop target", "Область сброса")).font(DS.Typo.headline) }
                }
                HStack(spacing: DS.Space.lg) {
                    GlassBackdrop(cornerRadius: 70).frame(width: 140, height: 140)
                        .overlay { Text(L("Disc", "Диск")).font(DS.Typo.headline) }
                    GlassBackdrop(cornerRadius: 70, tint: Brand.pink).frame(width: 140, height: 140)
                        .overlay { Text(L("Tinted", "С оттенком")).font(DS.Typo.headline) }
                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { i in
                                Text("\(i + 1)").font(DS.Typo.headline).frame(width: 44, height: 44).glassSurface(in: Circle(), tint: i == 1 ? Brand.pink : nil)
                            }
                        }
                    }
                }
                HStack(spacing: DS.Space.lg) {
                    GlassUnionDemo()
                    Text(L("Two shapes merge into one pill; the third stays apart.", "Две фигуры сливаются в одну капсулу, третья остаётся отдельно."))
                        .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Two glass shapes merged into one pill with `glassEffectUnion` (the union applies the shape to the combined frame, so use a Capsule, not a Circle), next to a third that stays separate.
struct GlassUnionDemo: View {
    @Namespace private var ns
    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "photo").frame(width: 44, height: 44).glassEffect(.regular, in: Capsule()).glassEffectUnion(id: "pair", namespace: ns)
                Image(systemName: "film").frame(width: 44, height: 44).glassEffect(.regular, in: Capsule()).glassEffectUnion(id: "pair", namespace: ns)
                Image(systemName: "waveform").frame(width: 44, height: 44).glassEffect(.regular, in: Circle())
            }
        }
        .symbolRenderingMode(.hierarchical)
    }
}
