import Foundation
import UniformTypeIdentifiers

// Extension sets, aliases, display names and key/base-name rules.
// A "key" is the normalised lower-case extension ("jpg", "tar.gz", "" for none). See spec/catalog.md section 1.

enum Formats {
    // MARK: Aliases and double extensions

    static let aliases: [String: String] = [
        "jpeg": "jpg", "jpe": "jpg", "jfif": "jpg", "tif": "tiff", "heif": "heic", "htm": "html",
        "markdown": "md", "aif": "aiff", "aifc": "aiff", "oga": "ogg", "tgz": "tar.gz", "m4v": "mp4",
        "tbz2": "tar.bz2", "tbz": "tar.bz2", "txz": "tar.xz", "tzst": "tar.zst", "mpg4": "mp4"
    ]

    /// Recognised before single extensions (only when the name is longer than the extension).
    static let doubleExtensions: [String] = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    // MARK: Sets (inputs)

    static let imageInputs: Set<String> = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "gif", "svg", "ico", "jp2", "jxl", "psd", "tga", "icns", "exr"]
    static let rawInputs: Set<String> = ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl", "pef", "srw", "3fr", "fff", "iiq", "erf", "kdc", "dcr", "mrw", "mos", "x3f", "gpr"]
    static let audioInputs: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "wma", "caf", "amr", "mka", "m4b", "m4r", "ac3"]
    static let videoInputs: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "ts", "mts", "m2ts", "ogv"]
    static let pdfInputs: Set<String> = ["pdf"]
    static let documentInputs: Set<String> = ["docx", "doc", "odt", "rtf", "md", "txt", "html", "epub"]
    static let slidesInputs: Set<String> = ["pptx", "ppt", "odp"]
    static let spreadsheetInputs: Set<String> = ["xlsx", "xlsm", "xls", "ods", "csv", "tsv"]
    static let subtitleInputs: Set<String> = ["srt", "vtt", "ass", "ssa", "sbv"]
    static let archiveInputs: Set<String> = ["zip", "tar", "tar.gz", "gz", "tar.bz2", "bz2", "tar.xz", "xz", "tar.zst", "zst", "rar", "7z"]

    /// Image inputs including camera RAW (RAW is an image input everywhere and is never written).
    static var imageAndRawInputs: Set<String> { imageInputs.union(rawInputs) }

    // MARK: Outputs offered on the wheel (Convert), in order. Studio offers more through its schemas.

    static let imageWheelOutputs = ["jpg", "png", "webp", "avif", "tiff", "ico", "pdf"]
    static let audioWheelOutputs = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
    static let videoWheelOutputs = ["mp4", "mov", "mkv", "webm", "gif", "mp3"]
    static let pdfWheelOutputs = ["docx", "jpg", "png", "pptx", "txt", "md", "html", "epub"]
    static let documentWheelOutputs = ["docx", "pdf", "odt", "md", "html", "txt", "epub", "rtf"]
    static let slidesWheelOutputs = ["pdf", "png", "jpg", "pptx", "odp"]
    static let spreadsheetWheelOutputs = ["xlsx", "csv", "tsv", "ods", "pdf"]
    static let subtitleWheelOutputs = ["srt", "vtt", "txt"]
    static let archiveWheelOutputs = ["zip", "tar", "tar.gz"]

    /// Output format for in-place edits: svg -> png, RAW -> jpg, otherwise the input format.
    static func outputFormatForEdit(of key: String) -> String {
        if key == "svg" { return "png" }
        if rawInputs.contains(key) { return "jpg" }
        return key
    }

    // MARK: Keys and names

    /// Normalised key of a file name: `a/photo.JPEG` -> "jpg", `backup.tar.gz` -> "tar.gz", `noext` -> "".
    static func key(forName name: String) -> String {
        let lower = name.lowercased()
        for d in doubleExtensions where lower.hasSuffix("." + d) && lower.count > d.count + 1 { return d }
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty { return "" }
        return aliases[ext] ?? ext
    }

    static func key(of url: URL) -> String { key(forName: url.lastPathComponent) }

    /// File name without its (possibly double) extension. A name that only has a leading dot keeps itself.
    /// A directory keeps its whole name.
    static func baseName(forName name: String, isDirectory: Bool = false) -> String {
        if isDirectory { return name }
        let lower = name.lowercased()
        for d in doubleExtensions where lower.hasSuffix("." + d) && lower.count > d.count + 1 {
            return String(name.dropLast(d.count + 1))
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return name }
        let base = ns.deletingPathExtension
        return base.isEmpty ? name : base
    }

    static func baseName(of url: URL, isDirectory: Bool = false) -> String {
        baseName(forName: url.lastPathComponent, isDirectory: isDirectory)
    }

    /// Label of a format tile: upper-case key ("tar.gz" -> "TAR.GZ").
    static func displayName(_ key: String) -> String { key.uppercased() }

    /// Friendly name used as a wheel subtitle for some targets (docx "Word", md "Markdown", ...). Nil when none.
    static func friendlyName(_ key: String) -> L10n? {
        switch key {
        case "docx": return L10n("Word", "Word")
        case "md": return L10n("Markdown", "Markdown")
        case "epub": return L10n("e-book", "электронная книга")
        case "txt": return L10n("text", "текст")
        case "html": return L10n("web", "веб")
        case "xlsx": return L10n("Excel", "Excel")
        case "pdf": return L10n("document", "документ")
        default: return nil
        }
    }

    // MARK: Kind detection

    /// Detects the kind from the key alone (no file system access). `.other` when unknown.
    static func kind(forKey key: String) -> FileKind {
        if imageInputs.contains(key) { return .image }
        if rawInputs.contains(key) { return .raw }
        if videoInputs.contains(key) { return .video }
        if audioInputs.contains(key) { return .audio }
        if pdfInputs.contains(key) { return .pdf }
        if documentInputs.contains(key) { return .document }
        if slidesInputs.contains(key) { return .slides }
        if spreadsheetInputs.contains(key) { return .spreadsheet }
        if subtitleInputs.contains(key) { return .subtitle }
        if archiveInputs.contains(key) { return .archive }
        return .other
    }

    /// Detects the kind from the system type database for extensions we do not list (e.g. "m2a", "dds").
    static func kind(forType type: UTType) -> FileKind {
        if type.conforms(to: .directory) || type.conforms(to: .folder) { return .folder }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .presentation) { return .slides }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .rtf) || type.conforms(to: .html) || type.conforms(to: .plainText) { return .document }
        return .other
    }

    /// UTType for a format key, when the system knows one.
    static func utType(forKey key: String) -> UTType? {
        let ext = key.contains(".") ? String(key.split(separator: ".").last ?? "") : key
        return UTType(filenameExtension: ext)
    }
}
