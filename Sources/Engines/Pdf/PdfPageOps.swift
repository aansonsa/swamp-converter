import Foundation
import PDFKit
import CoreGraphics

/// Page-level PDF work with PDFKit (merge, split plans, rotate, trim, extract) and Core Graphics (paper size). Pure functions of documents + options.
enum PdfPageOps {
    // MARK: Copies

    /// A new document holding copies of the given pages, in that order (copies, or the source document would lose them).
    static func copyPages(of doc: PDFDocument, indices: [Int]) -> PDFDocument {
        let out = PDFDocument()
        var at = 0
        for i in indices {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            out.insert(page, at: at)
            at += 1
        }
        return out
    }

    // MARK: Merge

    /// Order of the inputs: natural path order (Finder-like), by modification date, or as given.
    static func mergeOrder(_ items: [FileItem], mode: String) -> [FileItem] {
        switch mode {
        case "selection": return items
        case "date":
            func date(_ i: FileItem) -> Date { (try? i.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return items.sorted { date($0) < date($1) }
        default:
            let order = Util.naturalSorted(items.map(\.url))
            return order.compactMap { u in items.first { $0.url == u } }
        }
    }

    /// Appends all pages of all inputs; one bookmark per file when asked; `normalize` fits every page onto the first page's sheet.
    static func merge(_ ordered: [FileItem], bookmarks: Bool, normalize: Bool, stripMeta: Bool, to output: URL, ctx: OperationContext) async throws {
        let merged = PDFDocument()
        let root = PDFOutline()
        var at = 0
        for (i, item) in ordered.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            let doc = try PdfDoc.open(item.url)
            let start = at
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: at)
                at += 1
            }
            if bookmarks, let first = merged.page(at: start) {
                let entry = PDFOutline()
                entry.label = item.base
                entry.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).height))
                root.insertChild(entry, at: root.numberOfChildren)
            }
            ctx.report(Double(i + 1) / Double(ordered.count + 1))
        }
        guard merged.pageCount > 0 else { throw ConversionError.noOutput }
        if bookmarks { merged.outlineRoot = root }
        if stripMeta { PdfDoc.stripMetadata(merged) }
        if normalize, let first = merged.page(at: 0) {
            let temp = ctx.tempDir.appendingPathComponent("merged-\(Util.hex8()).pdf")
            try PdfDoc.write(merged, to: temp)
            try resize(source: temp, to: output, target: PdfGeometry.displayedSize(first), fixedOrientation: true, fit: .fit, marginPoints: 0, stripMeta: stripMeta)
            try? FileManager.default.removeItem(at: temp)
        } else {
            try PdfDoc.write(merged, to: output)
        }
    }

    // MARK: Split plans

    struct Chunk: Equatable, Sendable {
        var title: String
        var pages: [Int]
    }

    /// Chunks for eachPage, everyN, ranges and byBookmark (bySize needs the writer: see `splitBySize`).
    static func chunks(doc: PDFDocument, mode: String, every: Int, ranges: String) throws -> [Chunk] {
        let n = doc.pageCount
        switch mode {
        case "everyN":
            let step = max(1, every)
            return stride(from: 0, to: n, by: step).map { s in Chunk(title: "", pages: Array(s..<min(s + step, n))) }
        case "ranges":
            var out: [Chunk] = []
            for part in ranges.split(separator: ",") {
                let text = part.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard let list = PageRange.parse(text, pageCount: n), !list.isEmpty else {
                    throw ConversionError.invalidOption(key: PdfKeys.splitRanges, reason: L10n("Use ranges like 1-3, 5, 8- within the \(n) pages of the file.",
                                                                                              "Введите диапазоны, например 1-3, 5, 8-, в пределах \(n) стр. файла."))
                }
                out.append(Chunk(title: text, pages: list))
            }
            guard !out.isEmpty else { throw ConversionError.invalidOption(key: PdfKeys.splitRanges, reason: L10n("Enter at least one range.", "Введите хотя бы один диапазон.")) }
            return out
        case "byBookmark":
            return try bookmarkChunks(doc)
        default:
            return (0..<n).map { Chunk(title: "", pages: [$0]) }
        }
    }

    /// One chunk per top-level bookmark (pages up to the next bookmark). Pages before the first bookmark form their own chunk.
    static func bookmarkChunks(_ doc: PDFDocument) throws -> [Chunk] {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else {
            throw ConversionError.message(L10n("This PDF has no bookmarks to split by.", "В этом PDF нет закладок, по которым можно разделить."))
        }
        var starts: [(page: Int, title: String)] = []
        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i), let page = child.destination?.page else { continue }
            let idx = doc.index(for: page)
            if idx != NSNotFound, !starts.contains(where: { $0.page == idx }) { starts.append((idx, child.label ?? "")) }
        }
        starts.sort { $0.page < $1.page }
        guard !starts.isEmpty else {
            throw ConversionError.message(L10n("This PDF has no bookmarks to split by.", "В этом PDF нет закладок, по которым можно разделить."))
        }
        var out: [Chunk] = []
        if let first = starts.first, first.page > 0 { out.append(Chunk(title: L("Start", "Начало"), pages: Array(0..<first.page))) }
        for (i, s) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].page : doc.pageCount
            out.append(Chunk(title: s.title, pages: Array(s.page..<end)))
        }
        return out
    }

    /// Greedy fill: pages are added while the estimated file stays under `limitBytes`; every chunk is then measured by writing it and split
    /// again when it came out too big. A single page that is bigger than the limit stays alone.
    static func splitBySize(doc: PDFDocument, limitBytes: Int, ctx: OperationContext) async throws -> [Chunk] {
        let n = doc.pageCount
        var single: [Int] = []
        for i in 0..<n {
            try ctx.checkCancelled()
            single.append(copyPages(of: doc, indices: [i]).dataRepresentation()?.count ?? 0)
        }
        var groups: [[Int]] = []
        var current: [Int] = []
        var sum = 0
        for i in 0..<n {
            if !current.isEmpty && sum + single[i] > limitBytes { groups.append(current); current = []; sum = 0 }
            current.append(i); sum += single[i]
        }
        if !current.isEmpty { groups.append(current) }
        var result: [[Int]] = []
        func fit(_ pages: [Int]) throws {
            try ctx.checkCancelled()
            let size = copyPages(of: doc, indices: pages).dataRepresentation()?.count ?? 0
            if size <= limitBytes || pages.count == 1 { result.append(pages); return }
            let mid = pages.count / 2
            try fit(Array(pages[..<mid]))
            try fit(Array(pages[mid...]))
        }
        for g in groups { try fit(g) }
        return result.map { Chunk(title: "", pages: $0) }
    }

    // MARK: Rotate, trim, extract

    /// Adds `angle` degrees (clockwise) to the rotation of the pages the scope selects.
    static func rotate(_ doc: PDFDocument, angle: Int, scope: String, selection: Set<Int>) {
        guard angle % 360 != 0 else { return }
        for i in 0..<doc.pageCount {
            let number = i + 1
            let applies: Bool
            switch scope {
            case "odd": applies = number % 2 == 1
            case "even": applies = number % 2 == 0
            case "selected": applies = selection.contains(i)
            default: applies = true
            }
            if applies, let page = doc.page(at: i) { page.rotation = ((page.rotation + angle) % 360 + 360) % 360 }
        }
    }

    /// Cuts `millimetres` from every side of every page's crop box (never more than 40% of the smaller side).
    static func trim(_ doc: PDFDocument, millimetres: Double) {
        guard millimetres > 0 else { return }
        let inset = CGFloat(millimetres) * PdfGeometry.pointsPerMillimetre
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let d = min(inset, min(box.width, box.height) * 0.4)
            page.setBounds(box.insetBy(dx: d, dy: d), for: .cropBox)
        }
    }

    /// Keep or remove the selected pages, optionally in reverse order.
    static func extract(_ doc: PDFDocument, selection: [Int], mode: String, reverse: Bool) throws -> PDFDocument {
        var keep = selection
        if mode == "remove" {
            let drop = Set(selection)
            keep = (0..<doc.pageCount).filter { !drop.contains($0) }
        }
        guard !keep.isEmpty else {
            throw ConversionError.invalidOption(key: PdfKeys.pages, reason: L10n("That would remove every page.", "Так будут удалены все страницы."))
        }
        if reverse { keep.reverse() }
        return copyPages(of: doc, indices: keep)
    }

    // MARK: Paper size

    /// Redraws every page of `source` onto sheets of `target` points (or the page's own size when `target` is nil). With `fixedOrientation` false the sheet
    /// turns to landscape for landscape pages.
    static func resize(source: URL, to output: URL, target: CGSize?, fixedOrientation: Bool, fit: PdfComposer.Fit, marginPoints: CGFloat, stripMeta: Bool,
                       title: String? = nil, author: String? = nil) throws {
        guard let cg = CGPDFDocument(source as CFURL) else { throw ConversionError.fileUnreadable(source) }
        let composer = try PdfComposer(url: output, title: stripMeta ? nil : title, author: stripMeta ? nil : author)
        defer { composer.close() }
        for n in 1...max(cg.numberOfPages, 1) {
            guard let page = cg.page(at: n) else { continue }
            var sheet = target
            if let t = target, !fixedOrientation {
                let shown = PdfComposer.displayedSize(page)
                sheet = shown.width > shown.height ? CGSize(width: max(t.width, t.height), height: min(t.width, t.height))
                                                    : CGSize(width: min(t.width, t.height), height: max(t.width, t.height))
            }
            composer.addPage(page, target: sheet, fit: fit, margin: marginPoints)
        }
    }
}
