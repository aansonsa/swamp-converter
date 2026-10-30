import SwiftUI
import AppKit

// Previews of text-like files: subtitles (cue table, encoding picker with live re-decode) and spreadsheets (the first rows in a Table, delimiter hint). Reading goes through the data
// module's SubtitleKit and SheetReader; both run off the main thread and are cancelled when the file or the choice changes.

/// The text encodings the pickers offer. The raw values are the values of the schemas' `*.enc.in` fields.
enum StudioTextEncoding: String, CaseIterable, Identifiable {
    case auto, utf8 = "utf-8", utf16 = "utf-16", windows1251 = "windows-1251", windows1257 = "windows-1257", windows1250 = "windows-1250", windows1252 = "windows-1252"
    case koi8r = "koi8-r", cp866

    var id: String { rawValue }

    var title: L10n {
        switch self {
        case .auto: return L10n("Detect automatically", "Определять автоматически")
        case .utf8: return L10n("Unicode (UTF-8)", "Юникод (UTF-8)")
        case .utf16: return L10n("Unicode (UTF-16)", "Юникод (UTF-16)")
        case .windows1251: return L10n("Cyrillic (Windows-1251)", "Кириллица (Windows-1251)")
        case .windows1257: return L10n("Baltic (Windows-1257)", "Балтийская (Windows-1257)")
        case .windows1250: return L10n("Central European (Windows-1250)", "Центральная Европа (Windows-1250)")
        case .windows1252: return L10n("Western (Windows-1252)", "Западная (Windows-1252)")
        case .koi8r: return L10n("Cyrillic (KOI8-R)", "Кириллица (KOI8-R)")
        case .cp866: return L10n("Cyrillic (DOS 866)", "Кириллица (DOS 866)")
        }
    }

    /// nil = detect.
    var encoding: String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue))) }
        switch self {
        case .auto: return nil
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .windows1251: return .windowsCP1251
        case .windows1257: return cf(.windowsBalticRim)
        case .windows1250: return .windowsCP1250
        case .windows1252: return .windowsCP1252
        case .koi8r: return cf(.KOI8_R)
        case .cp866: return cf(.dosRussian)
        }
    }
}

/// A row for tables: SwiftUI needs identity, cues and cells have none.
struct IndexedRow<Value>: Identifiable {
    var id: Int
    var value: Value
}

struct PreviewSubtitleView: View {
    @ObservedObject var session: StudioSession
    var row: StudioSourceRow
    var bindings: PreviewBindings

    @State private var cues: [IndexedRow<SubtitleCue>] = []
    @State private var detected = ""
    @State private var error: String?
    @State private var loading = true
    @State private var localChoice = StudioTextEncoding.auto

    private static let shown = 400
    private var choice: StudioTextEncoding {
        if let k = bindings.subtitleEncodingKey, let raw = (session.resolved?.values ?? session.values)[k]?.asString, let e = StudioTextEncoding(rawValue: raw) { return e }
        return localChoice
    }
    private struct LoadKey: Equatable { var url: URL?; var choice: StudioTextEncoding }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                PreviewMessage(symbol: "captions.bubble", title: L("The subtitles can’t be read", "Не удаётся прочитать субтитры"), text: error)
            } else if loading && cues.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(cues) {
                    TableColumn("#") { r in Text("\(r.id + 1)").font(DS.Typo.numeric(DS.Typo.callout)).foregroundStyle(.secondary) }.width(min: 30, ideal: 40, max: 56)
                    TableColumn(L("Start", "Начало")) { r in Text(Util.formatTime(r.value.start, fraction: true)).font(DS.Typo.numeric(DS.Typo.callout)) }.width(min: 70, ideal: 84, max: 110)
                    TableColumn(L("End", "Конец")) { r in Text(Util.formatTime(r.value.end, fraction: true)).font(DS.Typo.numeric(DS.Typo.callout)) }.width(min: 70, ideal: 84, max: 110)
                    TableColumn(L("Text", "Текст")) { r in Text(r.value.text).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                }
                .accessibilityLabel(Text(L("Subtitle cues", "Реплики субтитров")))
            }
            Divider()
            PreviewControlBar {
                if !cues.isEmpty { InfoChip(Self.cueCount(cues.count), symbol: "text.bubble") }
                if !detected.isEmpty { InfoChip(L("Encoding: \(detected)", "Кодировка: \(detected)"), symbol: "character.cursor.ibeam") }
                encodingMenu
                if let b = row.sizeBytes { Text(Util.formatBytes(b)).font(DS.Typo.numeric(DS.Typo.caption)).foregroundStyle(.secondary) }
            }
        }
        .task(id: LoadKey(url: row.url, choice: choice)) { await load() }
    }

    static func cueCount(_ n: Int) -> String {
        Loc.plural(n, enOne: "\(n) cue", enOther: "\(n) cues", ruOne: "\(n) реплика", ruFew: "\(n) реплики", ruMany: "\(n) реплик")
    }

    private var encodingMenu: some View {
        Menu {
            ForEach(StudioTextEncoding.allCases) { e in
                Button { choose(e) } label: { Label(e.title.text, systemImage: e == choice ? "checkmark" : "character.cursor.ibeam") }
            }
        } label: {
            Label(L("Letters look wrong?", "Буквы отображаются неверно?"), systemImage: "textformat.abc").font(DS.Typo.caption.weight(.medium))
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
    }

    private func choose(_ e: StudioTextEncoding) {
        localChoice = e
        if let k = bindings.subtitleEncodingKey { session.set(k, .string(e.rawValue)) }
    }

    private func load() async {
        guard let url = row.url else { return }
        loading = true
        let enc = choice.encoding
        let result: Result<([SubtitleCue], String), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let (text, name) = try SubtitleKit.readText(url, encodingOverride: enc)
                return .success((try SubtitleKit.parse(text), name))
            } catch { return .failure(error) }
        }.value
        if Task.isCancelled { return }
        loading = false
        switch result {
        case .success(let (list, name)):
            cues = list.prefix(Self.shown).enumerated().map { IndexedRow(id: $0.offset, value: $0.element) }
            detected = name; error = nil
        case .failure(let e):
            cues = []; error = ConversionError.describe(e)
        }
    }
}

// MARK: - Spreadsheet

enum StudioDelimiter: String, CaseIterable, Identifiable {
    case auto, comma, semicolon, tab, pipe
    var id: String { rawValue }
    var title: L10n {
        switch self {
        case .auto: return L10n("Detect automatically", "Определять автоматически")
        case .comma: return L10n("Comma", "Запятая")
        case .semicolon: return L10n("Semicolon", "Точка с запятой")
        case .tab: return L10n("Tab", "Табуляция")
        case .pipe: return L10n("Vertical bar", "Вертикальная черта")
        }
    }
    var character: Character? {
        switch self { case .auto: return nil; case .comma: return ","; case .semicolon: return ";"; case .tab: return "\t"; case .pipe: return "|" }
    }
    static func from(_ c: Character?) -> StudioDelimiter? { allCases.first { $0.character == c && c != nil } }
}

struct PreviewSheetView: View {
    @ObservedObject var session: StudioSession
    var row: StudioSourceRow
    var bindings: PreviewBindings

    @State private var rows: [IndexedRow<[String]>] = []
    @State private var columns = 0
    @State private var detectedDelimiter: StudioDelimiter?
    @State private var detectedEncoding = ""
    @State private var error: String?
    @State private var loading = true
    @State private var note: String?
    @State private var localDelimiter = StudioDelimiter.auto
    @State private var localEncoding = StudioTextEncoding.auto

    private static let previewRows = 100
    /// Re-reading with an explicit delimiter or encoding parses the whole file; bigger files keep the automatic preview.
    private static let rereadLimit: Int64 = 25_000_000

    private var values: OptionValues { session.resolved?.values ?? session.values }
    private var delimiter: StudioDelimiter {
        if let k = bindings.sheetDelimiterKey, let e = values[k]?.asString.flatMap(StudioDelimiter.init(rawValue:)) { return e }
        return localDelimiter
    }
    private var encoding: StudioTextEncoding {
        if let k = bindings.sheetEncodingKey, let e = values[k]?.asString.flatMap(StudioTextEncoding.init(rawValue:)) { return e }
        return localEncoding
    }
    private var firstRowIsHeader: Bool { values.bool("sheet.header", true) }
    /// Delimiter and encoding exist only for text tables (csv, tsv); spreadsheets (xlsx, ods) are read by structure.
    private var isDelimited: Bool { ["csv", "tsv", "txt"].contains(row.url?.pathExtension.lowercased() ?? "") }
    private struct LoadKey: Equatable { var url: URL?; var delimiter: StudioDelimiter; var encoding: StudioTextEncoding }

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                PreviewMessage(symbol: "tablecells", title: L("The table can’t be read", "Не удаётся прочитать таблицу"), text: error)
            } else if loading && rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            Divider()
            PreviewControlBar {
                if columns > 0 { InfoChip(L("\(columns) columns", "Столбцов: \(columns)"), symbol: "rectangle.split.3x1") }
                if let d = detectedDelimiter { InfoChip(L("Delimiter: \(d.title.en.lowercased())", "Разделитель: \(d.title.ru.lowercased())"), symbol: "line.3.horizontal.decrease") }
                if !detectedEncoding.isEmpty { InfoChip(L("Encoding: \(detectedEncoding)", "Кодировка: \(detectedEncoding)"), symbol: "character.cursor.ibeam") }
                if isDelimited { delimiterMenu }
                if isDelimited { encodingMenu }
                if let note { Text(note).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .task(id: LoadKey(url: row.url, delimiter: delimiter, encoding: encoding)) { await load() }
    }

    @ViewBuilder private var table: some View {
        let header = firstRowIsHeader ? rows.first?.value : nil
        let body = firstRowIsHeader ? Array(rows.dropFirst()) : rows
        Table(body) {
            TableColumn("#") { r in Text("\(r.id + 1)").font(DS.Typo.numeric(DS.Typo.callout)).foregroundStyle(.secondary) }.width(min: 28, ideal: 36, max: 52)
            TableColumnForEach(0..<max(columns, 1), id: \.self) { c in
                TableColumn(Self.columnTitle(c, header: header)) { r in Text(r.value[safe: c] ?? "").lineLimit(2) }
            }
        }
        .accessibilityLabel(Text(L("First rows of the table", "Первые строки таблицы")))
    }

    /// "Name" from the header row, else the spreadsheet letters A, B ... Z, AA.
    static func columnTitle(_ index: Int, header: [String]?) -> String {
        if let h = header?[safe: index], !h.isEmpty { return h }
        var n = index, s = ""
        repeat { s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n = n / 26 - 1 } while n >= 0
        return s
    }

    private var delimiterMenu: some View {
        Menu {
            ForEach(StudioDelimiter.allCases) { d in
                Button { chooseDelimiter(d) } label: { Label(d.title.text, systemImage: d == delimiter ? "checkmark" : "line.3.horizontal.decrease") }
            }
        } label: { Label(L("Wrong delimiter?", "Неверный разделитель?"), systemImage: "line.3.horizontal.decrease").font(DS.Typo.caption.weight(.medium)) }
        .menuStyle(.button).controlSize(.small).fixedSize()
    }

    private var encodingMenu: some View {
        Menu {
            ForEach(StudioTextEncoding.allCases) { e in
                Button { chooseEncoding(e) } label: { Label(e.title.text, systemImage: e == encoding ? "checkmark" : "character.cursor.ibeam") }
            }
        } label: { Label(L("Letters look wrong?", "Буквы отображаются неверно?"), systemImage: "textformat.abc").font(DS.Typo.caption.weight(.medium)) }
        .menuStyle(.button).controlSize(.small).fixedSize()
    }

    private func chooseDelimiter(_ d: StudioDelimiter) {
        localDelimiter = d
        if let k = bindings.sheetDelimiterKey { session.set(k, .string(d.rawValue)) }
    }

    private func chooseEncoding(_ e: StudioTextEncoding) {
        localEncoding = e
        if let k = bindings.sheetEncodingKey { session.set(k, .string(e.rawValue)) }
    }

    private func load() async {
        guard let url = row.url else { return }
        loading = true
        let d = delimiter.character, e = encoding.encoding
        let canReread = (row.sizeBytes ?? 0) <= Self.rereadLimit
        let wantsOverride = d != nil || e != nil
        let previewRows = Self.previewRows
        let result: Result<SheetWorkbook, Error> = await Task.detached(priority: .userInitiated) {
            do {
                if wantsOverride && canReread { return .success(try SheetReader.read(url, encodingOverride: e, delimiterOverride: d)) }
                return .success(try SheetReader.preview(url, maxRows: previewRows))
            } catch { return .failure(error) }
        }.value
        if Task.isCancelled { return }
        loading = false
        switch result {
        case .success(let wb):
            let table = wb.sheets.first
            let list = (table?.rows ?? []).prefix(Self.previewRows + 1)
            rows = list.enumerated().map { IndexedRow(id: $0.offset, value: $0.element) }
            columns = table?.columnCount ?? 0
            detectedDelimiter = StudioDelimiter.from(wb.detectedDelimiter)
            detectedEncoding = wb.detectedEncoding ?? ""
            note = (wantsOverride && !canReread) ? L("This file is large; the preview keeps the automatic settings.", "Файл большой: в просмотре остаются автоматические настройки.") : nil
            error = nil
        case .failure(let err):
            rows = []; columns = 0; error = ConversionError.describe(err)
        }
    }
}
