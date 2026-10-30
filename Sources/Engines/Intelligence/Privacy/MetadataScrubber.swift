import Foundation

// D. Share-safe / privacy scrub: remove location and camera metadata, and say what was removed.

/// What a scrub removed (shown on the finished job card and by `swamp scrub --json`). `MetadataScrubber.inspect` returns the same type with `removed` holding
/// the items that are PRESENT (what a scrub could remove).
struct ScrubReport: Equatable, Sendable {
    enum Item: String, Codable, Sendable, CaseIterable {
        case gps, cameraMake, cameraModel, lensModel, serialNumber, dateTaken, software, author, title, comment, thumbnail, xmp, iptc, makerNote, creationTime, encoder, other
        var title: L10n {
            switch self {
            case .gps: return L10n("Location (GPS)", "Геопозиция (GPS)")
            case .cameraMake, .cameraModel: return L10n("Camera", "Камера")
            case .lensModel: return L10n("Lens", "Объектив")
            case .serialNumber: return L10n("Serial number", "Серийный номер")
            case .dateTaken, .creationTime: return L10n("Dates", "Даты")
            case .software, .encoder: return L10n("Software", "Программа")
            case .author: return L10n("Author", "Автор")
            case .title, .comment: return L10n("Title and comments", "Название и комментарии")
            case .thumbnail: return L10n("Embedded thumbnail", "Встроенный эскиз")
            case .xmp, .iptc, .makerNote, .other: return L10n("Other metadata", "Прочие метаданные")
            }
        }
    }
    var removed: [Item] = []
    var kept: [String] = []
    /// Items that were selected for removal but are still in the result (the format or the missing tool does not allow removing them).
    var residual: [Item] = []
    var isEmpty: Bool { removed.isEmpty }

    /// "Removed: location, camera, dates" / "Удалено: геопозиция, камера, даты" (duplicates collapsed, stable order).
    var summary: L10n {
        func names(_ items: [Item]) -> [L10n] { items.reduce(into: [L10n]()) { if !$0.contains($1.title) { $0.append($1.title) } } }
        let gone = names(removed)
        var text: L10n
        if gone.isEmpty {
            text = L10n("Nothing to remove: the file had no location or camera data.", "Удалять нечего: в файле не было геопозиции и данных камеры.")
        } else {
            text = L10n("Removed: " + gone.map { $0.en.lowercasedFirst }.joined(separator: ", "), "Удалено: " + gone.map { $0.ru.lowercasedFirst }.joined(separator: ", "))
        }
        let left = names(residual)
        if !left.isEmpty {
            text = L10n(text.en + ". Could not remove: " + left.map { $0.en.lowercasedFirst }.joined(separator: ", "),
                        text.ru + ". Не удалось удалить: " + left.map { $0.ru.lowercasedFirst }.joined(separator: ", "))
        }
        return text
    }

    /// Several files in one job: the union, stable order.
    static func merged(_ reports: [ScrubReport]) -> ScrubReport {
        var r = ScrubReport()
        for item in Item.allCases {
            if reports.contains(where: { $0.removed.contains(item) }) { r.removed.append(item) }
            if reports.contains(where: { $0.residual.contains(item) }) { r.residual.append(item) }
        }
        return r
    }
}

private extension String {
    /// "Location (GPS)" -> "location (GPS)" (keeps an all-caps first word such as "GPS").
    var lowercasedFirst: String {
        guard let first = split(separator: " ").first, first.uppercased() != String(first) else { return self }
        return prefix(1).lowercased() + dropFirst()
    }
}

/// Which groups of metadata a scrub removes. `everything` is the "wipe it all" switch (title, comments, thumbnails, XMP, IPTC and all technical tags too).
struct ScrubSelection: Equatable, Sendable {
    var gps = false
    /// Camera make / model, lens, serial numbers, maker notes, software and encoder tags.
    var device = false
    var dates = false
    var author = false
    var everything = false

    static let all = ScrubSelection(gps: true, device: true, dates: true, author: true, everything: true)

    init(gps: Bool = false, device: Bool = false, dates: Bool = false, author: Bool = false, everything: Bool = false) {
        self.gps = gps; self.device = device; self.dates = dates; self.author = author; self.everything = everything
    }

    /// Reads the `ScrubKeys` fields; fields that are inactive (disabled by "everything") are ignored.
    init(options o: OptionValues, isActive: (String) -> Bool = { _ in true }) {
        everything = o.bool(ScrubKeys.removeAll)
        gps = everything || (isActive(ScrubKeys.removeGPS) && o.bool(ScrubKeys.removeGPS))
        device = everything || (isActive(ScrubKeys.removeCamera) && o.bool(ScrubKeys.removeCamera))
        dates = everything || (isActive(ScrubKeys.removeDates) && o.bool(ScrubKeys.removeDates))
        author = everything || (isActive(ScrubKeys.removeAuthor) && o.bool(ScrubKeys.removeAuthor))
    }

    func selects(_ item: ScrubReport.Item) -> Bool {
        if everything { return true }
        switch item {
        case .gps: return gps
        case .cameraMake, .cameraModel, .lensModel, .serialNumber, .makerNote, .software, .encoder: return device
        case .dateTaken, .creationTime: return dates
        case .author: return author
        case .thumbnail: return gps || device
        case .title, .comment, .xmp, .iptc, .other: return false
        }
    }
}

enum MetadataScrubber {
    /// Inspects without changing anything: which of the `ScrubReport.Item`s are present (Studio inspector chip "Contains GPS").
    static func inspect(_ url: URL, kind: FileKind) async -> ScrubReport {
        switch kind {
        case .image, .raw: return ImageScrub.inspect(url)
        case .video, .audio: return await MediaScrub.inspect(url, tools: .shared)
        case .pdf: return PdfScrub.inspect(url)
        default: return ScrubReport()
        }
    }

    /// The extension of the scrubbed copy: the source's own, except images ImageIO cannot write (WebP, RAW, SVG ...), which become PNG (JPEG for RAW), and
    /// formats a PDF / media tool cannot keep.
    static func outputExtension(for item: FileItem) -> String {
        switch item.kind {
        case .image, .raw: return ImageScrub.outputExtension(for: item)
        default: return item.key.isEmpty ? "dat" : item.key
        }
    }

    /// Writes a scrubbed COPY (never the original) to `output` (a temp URL from `ctx.produceFile`): images via ImageIO (lossless copy of the pixels when possible,
    /// otherwise decode + encode with orientation baked in and the colour profile kept), video / audio via ffmpeg `-map_metadata -1 -c copy` (or an AVFoundation
    /// passthrough remux when ffmpeg is absent), PDF via PDFKit (a fresh document when the file carries XMP). Options come from `ctx.options` (`ScrubKeys`).
    /// Returns what was removed and what could not be.
    static func scrub(input: FileItem, output: URL, keepColorProfile: Bool, ctx: OperationContext, progress: ProgressSlice? = nil) async throws -> ScrubReport {
        let selection = ScrubSelection(options: ctx.options, isActive: ctx.isActive)
        let bake = ctx.options.bool(ScrubKeys.keepOrientation, true)
        return try await scrub(input: input, output: output, selection: selection, keepColorProfile: keepColorProfile, bakeOrientation: bake, ctx: ctx, progress: progress)
    }

    /// Same with an explicit selection (tests, CLI).
    static func scrub(input: FileItem, output: URL, selection: ScrubSelection, keepColorProfile: Bool, bakeOrientation: Bool = true,
                      allowFFmpeg: Bool = true, ctx: OperationContext, progress: ProgressSlice? = nil) async throws -> ScrubReport {
        try ctx.checkCancelled()
        switch input.kind {
        case .image, .raw:
            return try ImageScrub.scrub(input: input.url, output: output, selection: selection, keepProfile: keepColorProfile, bakeOrientation: bakeOrientation)
        case .video, .audio:
            return try await MediaScrub.scrub(input: input, output: output, selection: selection, allowFFmpeg: allowFFmpeg, ctx: ctx, progress: progress)
        case .pdf:
            return try PdfScrub.scrub(input: input.url, output: output, selection: selection)
        default:
            throw ConversionError.unsupported(L10n("Metadata removal does not support this kind of file.", "Для этого типа файлов удаление метаданных не поддерживается."))
        }
    }
}
