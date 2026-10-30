import Foundation
import PDFKit

/// Builds a PDF from two sources: pages that must stay EXACTLY as they are (copies of the source pages: content, invisible text layers, links, notes) and
/// freshly composed pages (pictures with a recognised text layer). Core Graphics cannot be used for the first kind: replaying a page into a new PDF context
/// drops text drawn in the "invisible" render mode, which is exactly what a searchable scan consists of.
enum PdfAssembly {
    /// - Parameters:
    ///   - doc: the source document.
    ///   - indices: source pages of the result, in order.
    ///   - kept: the members of `indices` that are copied from `doc`; every other member takes the next page of `fresh`, in order.
    ///   - fresh: a PDF holding one page per member of `indices` that is not in `kept` (nil when there is none).
    static func write(doc: PDFDocument, indices: [Int], kept: Set<Int>, fresh: URL?, stripMeta: Bool, options: [PDFDocumentWriteOption: Any]? = nil, to output: URL) throws {
        let replacement: PDFDocument? = fresh.flatMap { PDFDocument(url: $0) }
        let needed = indices.filter { !kept.contains($0) }.count
        guard needed == 0 || (replacement?.pageCount ?? 0) >= needed else { throw ConversionError.noOutput }
        let out = PDFDocument()
        var next = 0
        var position: [Int: Int] = [:]
        for index in indices {
            let page: PDFPage?
            if kept.contains(index) { page = doc.page(at: index)?.copy() as? PDFPage }
            else { page = replacement?.page(at: next)?.copy() as? PDFPage; next += 1 }
            guard let page else { continue }
            out.insert(page, at: out.pageCount)
            if position[index] == nil { position[index] = out.pageCount - 1 }
        }
        guard out.pageCount > 0 else { throw ConversionError.noOutput }
        if !stripMeta, let attrs = doc.documentAttributes, !attrs.isEmpty { out.documentAttributes = attrs }
        if !stripMeta { PdfDoc.copyOutline(from: doc, to: out, pageMap: position) }
        try PdfDoc.write(out, to: output, options: options)
        withExtendedLifetime(replacement) {}
        withExtendedLifetime(doc) {}
    }
}
