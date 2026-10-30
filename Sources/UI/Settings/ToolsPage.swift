import SwiftUI
import AppKit
import Combine

/// What each optional tool is for, and how to get it. The app never installs anything and never runs `brew`: it shows the command and copies it on request.
enum ToolsCatalog {
    struct Group: Identifiable {
        var id: String
        var title: L10n
        var tools: [Tool]
    }

    static let groups: [Group] = [
        Group(id: "media", title: L10n("Video, audio and images", "Видео, аудио и изображения"), tools: [.ffmpeg, .ffprobe, .cwebp, .magick, .lame, .flac, .sox]),
        Group(id: "docs", title: L10n("Documents and PDF", "Документы и PDF"), tools: [.soffice, .pandoc, .pdftotext]),
        Group(id: "archives", title: L10n("Archives", "Архивы"), tools: [.zstd, .xz]),
        Group(id: "downloads", title: L10n("Downloader", "Загрузчик"), tools: [.ytdlp, .deno, .node, .bun, .quickjs])
    ]

    static var allListed: [Tool] { groups.flatMap(\.tools) }

    /// One sentence: what turns on when the tool is found.
    static func unlocks(_ tool: Tool) -> L10n {
        switch tool {
        case .ffmpeg: return L10n("Video and audio conversion with more codecs and containers than macOS has (HEVC, AV1, VP9, MKV, WebM and more).",
                                  "Конвертация видео и аудио с большим набором кодеков и контейнеров, чем в macOS (HEVC, AV1, VP9, MKV, WebM и другие).")
        case .ffprobe: return L10n("Detailed information about video and audio files before a conversion.", "Подробные сведения о видео- и аудиофайлах перед конвертацией.")
        case .cwebp: return L10n("Saving images as WebP.", "Сохранение изображений в WebP.")
        case .magick: return L10n("Reading and writing more image formats.", "Чтение и запись большего числа форматов изображений.")
        case .lame: return L10n("MP3 encoding with LAME.", "Кодирование MP3 с помощью LAME.")
        case .flac: return L10n("FLAC encoding.", "Кодирование FLAC.")
        case .sox: return L10n("Extra audio processing.", "Дополнительная обработка звука.")
        case .soffice: return L10n("Converting Word, PowerPoint and Excel files, old and new, and exporting them to PDF.", "Конвертация файлов Word, PowerPoint и Excel, старых и новых, и экспорт в PDF.")
        case .pandoc: return L10n("More document conversions, such as Markdown, EPUB and DOCX in every direction.", "Больше конвертаций документов: Markdown, EPUB и DOCX в любом направлении.")
        case .pdftotext: return L10n("Faster text extraction from PDF files.", "Более быстрое извлечение текста из PDF.")
        case .zstd: return L10n("Zstandard archives (.zst, .tar.zst).", "Архивы Zstandard (.zst, .tar.zst).")
        case .xz: return L10n("XZ archives (.xz, .tar.xz).", "Архивы XZ (.xz, .tar.xz).")
        case .ytdlp: return L10n("Downloading videos and audio from links. Stays off until you give your consent in Settings > Downloader.",
                                 "Скачивание видео и аудио по ссылкам. Остаётся выключенным, пока вы не дадите согласие в Настройках > Загрузка.")
        case .deno, .node, .bun, .quickjs: return L10n("A JavaScript runtime that yt-dlp needs for some sites. One is enough.", "Среда JavaScript, которая нужна yt-dlp для некоторых сайтов. Достаточно одной.")
        default: return tool.installHint
        }
    }

    /// The `brew ...` command inside the install hint, or nil when the tool is not installed that way.
    static func brewCommand(for tool: Tool) -> String? {
        let hint = tool.installHint.en
        guard let r = hint.range(of: "brew ") else { return nil }
        return String(hint[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    static func sourceName(_ s: ToolSource) -> L10n {
        switch s {
        case .userOverride: return L10n("chosen by you", "выбран вами")
        case .bundled: return L10n("bundled", "встроен")
        case .userFolder: return L10n("tools folder", "папка инструментов")
        case .system: return L10n("system", "системный")
        case .homebrew: return L10n("Homebrew", "Homebrew")
        case .path: return L10n("from PATH", "из PATH")
        }
    }
}

/// Looks the tools up and reads their versions off the main thread (a version check starts the tool: up to 3 s each, and only when the page is open).
@MainActor
final class ToolsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var tool: Tool
        var path: String?
        var source: ToolSource?
        var version: String?
        var overridePath: String?
        var id: String { tool.rawValue }
        var found: Bool { path != nil }
        /// A path was chosen but it does not run, so the locator ignored it.
        var overrideRejected: Bool { overridePath != nil && source != .userOverride }
    }

    @Published private(set) var rows: [String: Row] = [:]
    private let locator: ToolLocator
    private let settings: AppSettings
    private var bag = Set<AnyCancellable>()
    private var loadToken = 0

    init(locator: ToolLocator = .shared, settings: AppSettings = .shared) {
        self.locator = locator
        self.settings = settings
        locator.$generation.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &bag)
        reload()
    }

    func row(_ tool: Tool) -> Row { rows[tool.rawValue] ?? Row(tool: tool) }

    var foundCount: Int { ToolsCatalog.allListed.filter { row($0).found }.count }

    /// Rebuilds every row from the locator, then fills in the versions in the background.
    func reload() {
        loadToken += 1
        let token = loadToken
        let overrides = settings.data.toolPaths
        var next: [String: Row] = [:]
        for tool in ToolsCatalog.allListed {
            let info = locator.find(tool)
            next[tool.rawValue] = Row(tool: tool, path: info?.path, source: info?.source, version: rows[tool.rawValue].flatMap { $0.path == info?.path ? $0.version : nil },
                                      overridePath: overrides[tool.rawValue])
        }
        rows = next
        let found = ToolsCatalog.allListed.filter { next[$0.rawValue]?.found == true && next[$0.rawValue]?.version == nil && $0.versionArguments != nil }
        guard !found.isEmpty else { return }
        let locator = self.locator
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for tool in found {
                let v = locator.version(of: tool)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.loadToken == token, var r = self.rows[tool.rawValue] else { return }
                        r.version = v
                        self.rows[tool.rawValue] = r
                    }
                }
            }
        }
    }

    /// "Check Again": forget every cached lookup (also the ffmpeg capability scan).
    func refresh() { locator.refresh() }

    /// Stores the path the person chose. Refuses a file that cannot run. Returns a calm message on refusal.
    @discardableResult
    func locate(_ tool: Tool, at url: URL) -> L10n? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            return L10n("That file can’t be run. Choose the program itself, not a folder or a document.", "Этот файл нельзя запустить. Выберите саму программу, а не папку или документ.")
        }
        settings.update { $0.toolPaths[tool.rawValue] = url.path }
        return nil
    }

    func clearOverride(_ tool: Tool) { settings.update { $0.toolPaths[tool.rawValue] = nil } }
}

/// Settings > Tools: what is installed, where, which version, what each tool unlocks, and how to get the missing ones.
struct ToolsPage: View {
    @StateObject private var model: ToolsModel
    @ObservedObject private var settings: AppSettings
    @State private var copied: Tool?
    @State private var problem: [Tool: String] = [:]

    init(settings: AppSettings = .shared, locator: ToolLocator = .shared) {
        _settings = ObservedObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: ToolsModel(locator: locator, settings: settings))
    }

    var body: some View {
        Form {
            FormSection(L("Optional tools", "Дополнительные инструменты"), symbol: "wrench.and.screwdriver",
                        footer: L("Everything works with what macOS already has. These programs only add formats. The app never runs Homebrew: copy a command and run it yourself. The one exception is yt-dlp, which Settings > Downloader can install for you (checked against its published checksum). macOS tools such as sips, afconvert, textutil and ditto are always there.",
                                  "Всё работает на том, что уже есть в macOS. Эти программы лишь добавляют форматы. Приложение не запускает Homebrew: скопируйте команду и выполните её сами. Исключение — yt-dlp: его может установить раздел Настройки > Загрузка (с проверкой опубликованной контрольной суммы). Инструменты macOS, такие как sips, afconvert, textutil и ditto, есть всегда.")) {
                SettingsRow(L("\(model.foundCount) of \(ToolsCatalog.allListed.count) found", "Найдено \(model.foundCount) из \(ToolsCatalog.allListed.count)")) {
                    Button(L("Check Again", "Проверить снова")) { model.refresh() }
                }
            }
            ForEach(ToolsCatalog.groups) { group in
                FormSection(group.title.text) {
                    ForEach(group.tools, id: \.self) { tool in toolRow(model.row(tool)) }
                }
            }
        }
        .formStyle(.grouped)
        .appRoot()
    }

    private func toolRow(_ row: ToolsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                StatusDot(row.found ? .done : .idle, size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(row.tool.displayName).font(.body.weight(.medium))
                Text(row.found ? L("Found", "Найден") : L("Not installed", "Не установлен")).font(DS.Typo.caption).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.md)
                if let version = row.version {
                    Text(Self.shortVersion(version)).font(DS.Typo.numeric(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 200, alignment: .trailing).textSelection(.enabled)
                }
            }
            Text(ToolsCatalog.unlocks(row.tool).text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let path = row.path, let source = row.source {
                Text("\(path)  \u{00B7}  \(ToolsCatalog.sourceName(source).text)").font(DS.Typo.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if row.overrideRejected {
                InlineMessage(L("The file you chose can’t be used, so the search went on. Choose it again or use the default.", "Выбранный вами файл не подходит, поэтому поиск продолжился. Выберите его снова или верните значение по умолчанию."), tone: .warning)
            }
            if let p = problem[row.tool] { InlineMessage(p, tone: .warning, onDismiss: { problem[row.tool] = nil }) }
            actions(row)
        }
        .padding(.vertical, DS.Space.xxs)
        .accessibilityElement(children: .contain)
        .settingsKey("toolPaths")
    }

    @ViewBuilder private func actions(_ row: ToolsModel.Row) -> some View {
        HStack(spacing: DS.Space.sm) {
            if !row.found, row.tool == .ytdlp {
                Button(L("Install in Downloader…", "Установить в разделе «Загрузка»…")) { SettingsWindowController.shared.show(page: .downloader) }
                    .controlSize(.small)
            }
            if !row.found, let cmd = ToolsCatalog.brewCommand(for: row.tool) {
                Text(cmd).font(DS.Typo.mono).textSelection(.enabled).lineLimit(1).truncationMode(.tail)
                Button(copied == row.tool ? L("Copied", "Скопировано") : L("Copy Command", "Скопировать команду")) { copy(cmd, for: row.tool) }
                    .controlSize(.small)
            } else if !row.found {
                Text(row.tool.installHint.text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.sm)
            Button(L("Locate…", "Указать…")) { locate(row.tool) }.controlSize(.small)
            if row.overridePath != nil { Button(L("Use Default", "По умолчанию")) { problem[row.tool] = nil; model.clearOverride(row.tool) }.controlSize(.small) }
        }
    }

    private func copy(_ command: String, for tool: Tool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = tool
    }

    private func locate(_ tool: Tool) {
        guard let url = SettingsPanels.chooseFile(title: L("Choose \(tool.displayName)", "Выберите \(tool.displayName)"), types: nil,
                                                  start: URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)) else { return }
        problem[tool] = model.locate(tool, at: url)?.text
    }

    /// "ffmpeg version 7.1.1 Copyright ..." -> "7.1.1"; unknown shapes are shown as they are.
    static func shortVersion(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        if let i = words.firstIndex(of: "version"), words.indices.contains(i + 1) { return words[i + 1] }
        if let w = words.first(where: { $0.first?.isNumber == true }) { return w }
        return line
    }
}
