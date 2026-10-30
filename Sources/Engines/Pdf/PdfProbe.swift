import Foundation
import PDFKit

/// Facts about a PDF for the Studio inspector and option conditions: pdf.pages, pdf.encrypted, pdf.hasText, pdf.width / pdf.height (points, as a viewer shows
/// the first page), pdf.paper. Cheap: pages are not rendered; only the first three pages are asked for text.
struct PdfSourceProbe: SourceProbe {
    func probe(_ item: FileItem) async -> SourceInfo {
        var info = SourceInfo(url: item.url, kind: item.kind)
        guard let doc = PDFDocument(url: item.url) else {
            info.warnings.append(L10n("The file could not be read as a PDF.", "Файл не удаётся прочитать как PDF."))
            return info
        }
        info.facts["pdf.encrypted"] = .bool(doc.isEncrypted)
        if doc.isLocked {
            info.facts["pdf.locked"] = .bool(true)
            info.chips.append(SourceChip(symbol: "lock", text: L("Password", "Пароль")))
            info.warnings.append(L10n("The file is protected with a password. Remove it first (Tools > Unlock).", "Файл защищён паролем. Сначала снимите его (Инструменты > Снять пароль)."))
            return info
        }
        let count = doc.pageCount
        info.facts["pdf.pages"] = .int(count)
        info.chips.append(SourceChip(symbol: "doc.on.doc", text: Loc.pages(count)))
        if let first = doc.page(at: 0) {
            let size = PdfGeometry.displayedSize(first)
            info.facts["pdf.width"] = .double(Double(size.width))
            info.facts["pdf.height"] = .double(Double(size.height))
            if let paper = PdfGeometry.paperName(size) {
                info.facts["pdf.paper"] = .string(paper)
                info.chips.append(SourceChip(symbol: "ruler", text: paper))
            }
        }
        var checked = 0, withText = 0
        for i in 0..<min(count, 3) {
            guard let page = doc.page(at: i) else { continue }
            checked += 1
            if PdfGeometry.hasText(page) { withText += 1 }
        }
        let hasText = withText > 0
        info.facts["pdf.hasText"] = .bool(hasText)
        if checked > 0 && !hasText {
            info.chips.append(SourceChip(symbol: "text.viewfinder", text: L("Scan", "Скан")))
            info.warnings.append(L10n("The pages are pictures with no text. Text recognition can make them searchable.", "Страницы — картинки без текста. Распознавание сделает их доступными для поиска."))
        }
        if doc.isEncrypted {
            info.chips.append(SourceChip(symbol: "lock", text: L("Restricted", "С ограничениями")))
            if !(doc.allowsCopying && doc.allowsPrinting && doc.allowsDocumentChanges) {
                info.warnings.append(L10n("The file restricts printing, copying or editing.", "Файл ограничивает печать, копирование или правку."))
            }
        }
        return info
    }
}
