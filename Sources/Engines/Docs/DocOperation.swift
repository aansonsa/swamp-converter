import Foundation

// One document or slides operation. Behaviour is a pure function of (item, ctx.options): the target format is the `doc.format` option (the operation's quick recipe sets it),
// never the operation id. Availability is the per-file route test; slides need LibreOffice (declared in the metadata, shown disabled with the install hint).

final class DocOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues
    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) { self.quick = quick; super.init(meta: meta) }

    var isSlides: Bool { meta.schemaID == DocSchemas.slidesID }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { isSlides ? DocSchemas.slides(items: items) : DocSchemas.convert(items: items) }
    override func privacyOverrides() -> OptionValues { isSlides ? OptionValues() : [DocKeys.metaMode: "strip"] }

    // MARK: Availability

    /// Per-file route test (spec/catalog.md 3.5): every file needs a way to reach the target. The built-in engine reaches every pair of the eight formats, so this
    /// only fails when the system tool behind the legacy formats (textutil) is missing.
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        let base = super.availability(for: items, tools: tools)
        guard base.isAvailable, !isSlides else { return base }
        let target = meta.targetFormat ?? "pdf"
        for item in items {
            if case .none(let reason, let missing) = DocRouter.route(input: item.key, target: target, tools: tools) {
                return .unavailable(reason: reason, missing: missing)
            }
        }
        return .available
    }

    // MARK: Running

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        if isSlides { return try await DocSlides.process(item, ctx: ctx, progress: progress) }
        let o = ctx.options
        let target = o.string(DocKeys.format, meta.targetFormat ?? "pdf")
        var report = DocRunReport()
        let url = try await ctx.produceFile(for: item, ext: target) { tmp in
            report = try await DocConverter.convertDetailed(input: item.url, to: target, output: tmp, options: o, ctx: ctx, progress: progress)
        }
        progress.report(1)
        return [url] + report.extras
    }

    // MARK: Studio

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        if isSlides { return validateSlides(options: options) }
        var s = DocSettings(options)
        let inKey = source.map { Formats.key(of: $0.url) } ?? ""
        let target = s.target
        var out: [OptionMessage] = []
        let ignored = s.nativeOnlyChanges(for: target)
        s.engine = options.string(DocKeys.engine, "auto")
        if inKey.isEmpty {
            out.append(OptionMessage(id: "doc.route", severity: .info, text: DocRoute.native.explanation))
            return out
        }
        switch DocRouter.route(input: inKey, target: target, engine: s.engine, nativeOptionsChanged: !ignored.isEmpty, tools: ToolLocator.shared) {
        case .route(let r):
            out.append(OptionMessage(id: "doc.route", severity: .info, text: L10n("Engine: \(r.label.en). ", "Движок: \(r.label.ru). ").combined(with: r.explanation), fieldKey: DocKeys.engine))
            if s.engine != "auto", r != .native, r != .sofficeThenNative, !ignored.isEmpty {
                let names = ignored.map { Self.optionName($0) }
                out.append(OptionMessage(id: "doc.ignored", severity: .warning,
                                         text: L10n("\(r.label.en) does not apply: \(names.map(\.en).joined(separator: ", ")). Choose Automatic or Built-in to use them.",
                                                    "\(r.label.ru) не применяет: \(names.map(\.ru).joined(separator: ", ")). Выберите «Автоматически» или «Встроенный», чтобы они действовали."), fieldKey: DocKeys.engine))
            }
        case .none(let reason, _):
            out.append(OptionMessage(id: "doc.noroute", severity: .error, text: reason, fieldKey: DocKeys.engine))
        }
        if DocRouter.pageTargets.contains(target), s.font != "auto", !PdfFonts.isInstalled(s.font) {
            out.append(OptionMessage(id: "doc.font", severity: .warning, text: L10n("The font \(s.font) is not installed on this Mac; a substitute is used.", "Шрифт \(s.font) не установлен на этом Mac; будет использована замена."), fieldKey: DocKeys.font))
        }
        if inKey == "txt" || inKey == "md" || inKey == "html" || target == "txt" {
            if s.encodingIn != "auto" && inKey == "docx" {
                out.append(OptionMessage(id: "doc.enc.ignored", severity: .info, text: L10n("The source encoding applies to TXT, MD and HTML sources only.", "Кодировка исходника применяется только к файлам TXT, MD и HTML.")))
            }
        }
        return out
    }

    private func validateSlides(options: OptionValues) -> [OptionMessage] {
        let range = options.string(DocKeys.slideRange)
        if !range.isEmpty, range.lowercased() != "all", DocPageRange.indices(range, count: 100_000) == nil {
            return [OptionMessage(id: "slides.range", severity: .error, text: L10n("Write slides like 1-3, 5.", "Укажите слайды так: 1-3, 5."), fieldKey: DocKeys.slideRange)]
        }
        return []
    }

    static func optionName(_ key: String) -> L10n {
        switch key {
        case DocKeys.pageSize: return L10n("paper size", "размер бумаги")
        case DocKeys.margins: return L10n("margins", "поля")
        case DocKeys.font: return L10n("font", "шрифт")
        case DocKeys.fontSize: return L10n("font size", "размер шрифта")
        case DocKeys.lineSpacing: return L10n("line spacing", "межстрочный интервал")
        case DocKeys.pageNumbers: return L10n("page numbers", "номера страниц")
        case DocKeys.encodingOut: return L10n("encoding", "кодировка")
        case DocKeys.encodingIn: return L10n("source text options", "параметры исходного текста")
        case DocKeys.bom: return L10n("BOM", "BOM")
        case DocKeys.eol: return L10n("line endings", "концы строк")
        case DocKeys.wrap: return L10n("line wrapping", "перенос строк")
        case DocKeys.mdFlavor: return L10n("Markdown options", "параметры Markdown")
        case DocKeys.htmlSingleFile: return L10n("single-file option", "режим одного файла")
        case DocKeys.epubSplit: return L10n("e-book options", "параметры книги")
        case DocKeys.images: return L10n("removing pictures", "удаление картинок")
        case DocKeys.metaMode: return L10n("removing metadata", "удаление метаданных")
        case DocKeys.title: return L10n("title, author and language", "название, автор и язык")
        default: return L10n(key)
        }
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        let target = options.string(DocKeys.format, meta.targetFormat ?? "pdf")
        var chips = [Formats.displayName(target)]
        if isSlides {
            if target == "png" || target == "jpg" { chips.append("\(options.int(DocKeys.slideDPI, 300)) dpi") }
            let r = options.string(DocKeys.slideRange)
            if !r.isEmpty, r.lowercased() != "all" { chips.append(L("slides \(r)", "слайды \(r)")) }
            return chips
        }
        let s = DocSettings(options)
        if DocRouter.pageTargets.contains(target) { chips.append(s.pageSize == "auto" ? L("by region", "по региону") : s.pageSize.uppercased()) }
        if ["txt", "md", "html"].contains(target) { chips.append(s.encodingOut.uppercased()) }
        if s.engine != "auto" { chips.append(DocRoute(rawValue: s.engine)?.label.text ?? s.engine) }
        if s.stripImages { chips.append(L("no pictures", "без картинок")) }
        if s.stripMetadata { chips.append(L("no metadata", "без метаданных")) }
        return chips
    }

    /// Cheap and rough: ratios by target. Documents have no encoder to sample; the number is a guide for the free-space check, not a promise.
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let size = Double(items.compactMap(\.size).reduce(0, +))
        guard size > 0 else { return nil }
        let target = options.string(DocKeys.format, meta.targetFormat ?? "pdf")
        let factor: Double
        switch target {
        case "txt", "md": factor = 0.8
        case "html": factor = options.bool(DocKeys.htmlSingleFile, true) ? 1.6 : 1.0
        case "pdf": factor = 1.1
        case "png", "jpg": factor = 6
        case "rtf": factor = 3
        default: factor = 1.0
        }
        return OperationEstimate(bytes: Int64(size * factor) + 20_000, seconds: 1 + size / 4_000_000, confidence: .rough,
                                 note: L10n("Documents have no encoder to measure; this is a rough guide.", "У документов нет кодировщика для замера; это лишь ориентир."))
    }

    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        guard let first = items.first else { return nil }
        let image = await ThumbnailCache.shared.thumbnail(for: first.url, kind: first.kind, maxPixel: maxPixel)
        try Task.checkCancellation()
        guard let image else { return nil }
        return OperationPreview(before: image, after: nil, note: L10n("The preview shows the first page of the original. The result is made when you start.",
                                                                       "Предпросмотр показывает первую страницу оригинала. Результат создаётся при запуске."))
    }
}

extension L10n {
    func combined(with other: L10n) -> L10n { L10n(en + other.en, ru + other.ru) }
}
