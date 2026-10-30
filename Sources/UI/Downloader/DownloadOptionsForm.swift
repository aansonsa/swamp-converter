import SwiftUI
import AppKit

// The choices under the info card, as the sections of a native grouped Form (spec/handbrake.md 6: Studio inspector conventions; "disabled with a reason"):
// What to get (the Smart module's modes + audio), Quality, After download, Save to, Subtitles, Part of the video. A list gets the same form with a height cap
// instead of the per-quality rows (its entries have no format list yet).

struct DownloadOptionsForm: View {
    @ObservedObject var model: DownloadSheetModel

    var body: some View {
        modeSection
        qualitySection
        if !model.isAudio { afterSection }
        folderSection
        if !model.isAudio { subtitleSection }
        if model.info?.isPlaylist == false { rangeSection }
    }

    // MARK: Mode

    private var modeSection: some View {
        FormSection(L("What to get", "Что скачать"), symbol: "square.and.arrow.down") {
            AdaptivePicker(L("What to get", "Что скачать"), selection: $model.modeChoice,
                           options: DownloadModeChoice.allCases.map { (value: $0, label: $0.title.text) })
            FormFootnote(model.modeChoice.explanation.text)
        }
    }

    // MARK: Quality

    @ViewBuilder private var qualitySection: some View {
        if model.isAudio {
            FormSection(L("Audio format", "Формат звука"), symbol: "waveform", footer: model.estimatedBytes.map { DownloadFormatText.size($0) }) {
                QualityPickerView(options: [], selectedID: .constant(nil), audioFormat: $model.audioFormat)
                if model.audioFormat == .mp3 { FormFootnote(L("MP3 is encoded at the best variable quality.", "MP3 кодируется с лучшим переменным качеством.")) }
            }
        } else if model.phase == .playlist {
            FormSection(L("Quality", "Качество"), symbol: "film") {
                Picker(L("Largest picture", "Максимальный размер картинки"), selection: $model.listMaxHeight) {
                    Text(L("Best available", "Лучшее доступное")).tag(0)
                    ForEach([2160, 1440, 1080, 720, 480, 360], id: \.self) { Text(DownloadFormatText.resolutionName($0)).tag($0) }
                }
                FormFootnote(L("Each video is downloaded in the best quality up to this size. A video that offers less is downloaded as it is.",
                               "Каждое видео скачивается в лучшем качестве до этого размера. Если у видео оно ниже, оно скачивается как есть."))
            }
        } else if !model.qualityOptions.isEmpty {
            FormSection(L("Quality", "Качество"), symbol: "film", footer: model.estimatedBytes.map { DownloadFormatText.size($0) }) {
                QualityPickerView(options: model.qualityOptions, selectedID: $model.qualityID)
            }
        }
    }

    // MARK: After download

    private var afterSection: some View {
        FormSection(L("After download", "После загрузки"), symbol: "arrow.triangle.2.circlepath",
                    footer: model.modeChoice == .maximum ? L("Maximum quality keeps the file exactly as the site stores it.", "«Максимальное качество» оставляет файл таким, как его хранит сайт.") : nil) {
            Picker(L("After download", "После загрузки"), selection: $model.after) {
                Text(L("Keep as downloaded", "Оставить как скачано")).tag(AfterDownload.keepOriginal)
                Text(SmartMode.bestForApple.title.text).tag(AfterDownload.bestForApple)
                Text(SmartMode.universal.title.text).tag(AfterDownload.universal)
            }
            .disabled(model.modeChoice == .maximum)
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        let shown = model.folder ?? model.deps.outputDirectory(model.effectiveMode)
        return FormSection(L("Save to", "Куда сохранить"), symbol: "folder") {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(Self.abbreviated(shown)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: DS.Space.sm)
                if model.folder != nil { Button(L("Default", "По умолчанию")) { model.folder = nil }.buttonStyle(.link).foregroundStyle(Brand.blueInk) }
                Button(L("Choose…", "Выбрать…")) { if let url = DownloadFolderChooser.choose(starting: shown) { model.folder = url } }
                    .secondaryButtonLook().controlSize(.small)
            }
        }
    }

    static func abbreviated(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    // MARK: Subtitles

    @ViewBuilder private var subtitleSection: some View {
        FormSection(L("Subtitles", "Субтитры"), symbol: "captions.bubble") {
            AdaptivePicker(L("Subtitles", "Субтитры"), selection: $model.subtitleMode, options: [
                (value: .none, label: L("None", "Нет")),
                (value: .soft, label: L("Inside the video", "В видео")),
                (value: .external, label: L("Separate file", "Отдельный файл"))
            ])
            if model.subtitleMode != .none {
                TextField(L("Languages", "Языки"), text: $model.subtitleLanguages, prompt: Text("en,de"))
                if let info = model.info, !info.subtitles.isEmpty {
                    FormFootnote(L("Offered: ", "Есть: ") + Self.languages(info.subtitles))
                } else {
                    FormFootnote(L("Language codes separated by commas. Automatic captions are used when the author added none.",
                                   "Коды языков через запятую. Если автор не добавил субтитры, берутся автоматические."))
                }
            }
        }
    }

    /// "ru, en, lv (auto)" from the tracks the page offers (at most eight).
    static func languages(_ tracks: [DownloadSubtitleTrack]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for t in tracks where seen.insert(t.language + (t.isAutomatic ? "#auto" : "")).inserted {
            out.append(t.isAutomatic ? "\(t.language) (\(L("auto", "авто")))" : t.language)
        }
        return out.prefix(8).joined(separator: ", ") + (out.count > 8 ? ", ..." : "")
    }

    // MARK: Range

    private var rangeSection: some View {
        FormSection(L("Part of the video", "Часть видео"), symbol: "scissors") {
            HStack(spacing: DS.Space.md) {
                TextField(L("From", "От"), text: $model.rangeStart, prompt: Text(L("start", "начало")))
                TextField(L("To", "До"), text: $model.rangeEnd, prompt: Text(L("end", "конец")))
            }
            .disabled(!model.ffmpegAvailable)
            if let problem = model.rangeProblem { InlineMessage(problem, tone: .warning) }
            else { FormFootnote(L("Leave both empty to download everything. The cut snaps to the nearest keyframe.", "Оставьте оба поля пустыми, чтобы скачать всё. Вырезка округляется до ближайшего ключевого кадра.")) }
        }
    }
}

/// The folder chooser (an open panel limited to folders). The panel is modal and only opens from a button press.
@MainActor
enum DownloadFolderChooser {
    static func choose(starting: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose", "Выбрать")
        panel.directoryURL = starting
        return panel.runModal() == .OK ? panel.url : nil
    }
}
