import Foundation
import UniformTypeIdentifiers

// Core value types: wheels, file kinds, file items, operation families.

/// The radial wheels. Three belong to files (convert / tools / actions); `link` is the download wheel that appears when the
/// input is a web link (its sectors are download modes, see DownloadMode).
enum WheelKind: String, Codable, CaseIterable, Sendable {
    case convert, tools, actions, link

    /// The wheels reachable with the three modifier keys.
    static let fileWheels: [WheelKind] = [.convert, .tools, .actions]

    var title: L10n {
        switch self {
        case .convert: return L10n("Convert", "Конвертация")
        case .tools: return L10n("Tools", "Инструменты")
        case .actions: return L10n("Actions", "Действия")
        case .link: return L10n("Download", "Скачать")
        }
    }
    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .actions: return "bolt"
        case .link: return "arrow.down.circle"
        }
    }
}

/// Coarse content kind of one dropped item.
enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, raw, audio, video, pdf, document, slides, spreadsheet, subtitle, archive, folder, other

    /// RAW behaves as an image input everywhere.
    var isImageLike: Bool { self == .image || self == .raw }

    var title: L10n {
        switch self {
        case .image: return L10n("Image", "Изображение")
        case .raw: return L10n("RAW photo", "RAW-фото")
        case .audio: return L10n("Audio", "Аудио")
        case .video: return L10n("Video", "Видео")
        case .pdf: return L10n("PDF", "PDF")
        case .document: return L10n("Document", "Документ")
        case .slides: return L10n("Presentation", "Презентация")
        case .spreadsheet: return L10n("Spreadsheet", "Таблица")
        case .subtitle: return L10n("Subtitles", "Субтитры")
        case .archive: return L10n("Archive", "Архив")
        case .folder: return L10n("Folder", "Папка")
        case .other: return L10n("File", "Файл")
        }
    }
}

/// Which engine family an operation belongs to. Used for grouping in Studio and in the wheel editor.
enum OperationFamily: String, Codable, CaseIterable, Sendable {
    case image, audio, video, pdf, document, slides, spreadsheet, subtitle, archive, ocr, download, app

    var title: L10n {
        switch self {
        case .image: return L10n("Images", "Изображения")
        case .audio: return L10n("Audio", "Аудио")
        case .video: return L10n("Video", "Видео")
        case .pdf: return L10n("PDF", "PDF")
        case .document: return L10n("Documents", "Документы")
        case .slides: return L10n("Presentations", "Презентации")
        case .spreadsheet: return L10n("Spreadsheets", "Таблицы")
        case .subtitle: return L10n("Subtitles", "Субтитры")
        case .archive: return L10n("Archives", "Архивы")
        case .ocr: return L10n("Text recognition", "Распознавание текста")
        case .download: return L10n("Downloads", "Загрузки")
        case .app: return L10n("Anything", "Любые файлы")
        }
    }
}

/// One dropped / selected item. Immutable snapshot taken when the item enters the app.
struct FileItem: Hashable, Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    /// Normalised format key ("jpg", "tar.gz", ""). Empty for folders.
    let key: String
    let kind: FileKind
    let size: Int64?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var base: String { Formats.baseName(of: url, isDirectory: isDirectory) }
    var parent: URL { url.deletingLastPathComponent() }

    /// Inspects the file system (directory flag, size) and detects the kind by extension first, then by UTType.
    init(url: URL) {
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .isPackageKey])
        let dir = rv?.isDirectory ?? url.hasDirectoryPath
        self.init(url: url, isDirectory: dir, size: rv?.fileSize.map(Int64.init), contentType: rv?.contentType)
    }

    /// Testing / pre-resolved initialiser: no file-system access when `contentType` is nil.
    init(url: URL, isDirectory: Bool, size: Int64? = nil, contentType: UTType? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        if isDirectory {
            self.key = ""
            self.kind = .folder
        } else {
            let k = Formats.key(of: url)
            self.key = k
            var kind = Formats.kind(forKey: k)
            if kind == .other {
                if let t = contentType ?? Formats.utType(forKey: k) { kind = Formats.kind(forType: t) }
            }
            self.kind = kind
        }
    }

    static func items(_ urls: [URL]) -> [FileItem] { urls.map { FileItem(url: $0) } }
}

extension Array where Element == FileItem {
    /// True when every item satisfies `predicate` and the list is not empty.
    func allSatisfy(nonEmpty predicate: (FileItem) -> Bool) -> Bool { !isEmpty && allSatisfy(predicate) }
    var kinds: Set<FileKind> { Set(map(\.kind)) }
    var urls: [URL] { map(\.url) }
    /// "report.pdf" for one item, "5 files" for several.
    var summaryTitle: String { count == 1 ? self[0].name : Loc.files(count) }
}
