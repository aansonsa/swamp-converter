import Foundation
import CoreGraphics

// Test and snapshot fixtures of the studio-core module: a schema that contains EVERY FieldKind, fake operations that share it, and a harness that builds an isolated
// session (own registry, settings file, preset store and job runner) so nothing a test does can touch the app's real state.

enum FixtureKeys {
    static let container = "container", mode = "mode", fast = "fast"
    static let quality = "quality", bitrate = "bitrate", rc = "rc", refs = "refs", maxrate = "maxrate"
    static let trimStart = "trim.start", trimEnd = "trim.end"
    static let title = "title", comment = "comment", password = "password", bg = "bg", outdir = "outdir", cover = "cover"
    static let tracks = "audio.tracks", limit = "size.limit", gated = "gated.toggle"
}

/// Counters the fake operations bump (thread-safe: estimate / preview run off the main thread).
final class FixtureHooks: @unchecked Sendable {
    let estimateCalls = Locked(0)
    let chipCalls = Locked(0)
    let previewStarted = Locked(0)
    let previewCancelled = Locked(0)
    let previewFinished = Locked(0)
    /// How long a preview takes (nanoseconds); it checks cancellation while waiting.
    let previewDelay = Locked<UInt64>(0)
}

enum StudioFixture {
    static let schemaID = "test.studio"

    /// Every FieldKind, conditions, a capability gate, a log slider, computed defaults, validation rules, expert fields, a second page with more than six fields in a group,
    /// aliases in both languages and a page that needs a missing tool.
    static func schema() -> OptionSchema {
        let audioColumns: [OptionField] = [
            .number("source", L10n("Source stream", "Исходный поток"), min: 0, max: 31, def: 0),
            .picker("codec", L10n("Codec", "Кодек"), [FieldOption("aac", "AAC"), FieldOption("alac", "ALAC"), FieldOption("copy", L10n("Copy", "Копировать"))], def: "aac"),
            .stepper("bitrate", L10n("Bitrate", "Битрейт"), min: 64, max: 512, step: 32, def: 160, unit: "kbit/s").enabled(.ne("codec", "alac")),
            .text("lang", L10n("Language", "Язык"), def: ""),
            .text("title", L10n("Name", "Название"), def: "")
        ]
        let main = OptionPage.make("main", symbol: "film", L10n("Video", "Видео"), [
            .make("format", L10n("Format", "Формат"), [
                .picker(FixtureKeys.container, L10n("Container", "Контейнер"),
                        [FieldOption("mp4", "MP4"), FieldOption("mov", "MOV"), FieldOption("mkv", "MKV", requires: ["tool.nonexistent"])], def: "mp4")
                    .basic().oracle("container").aliases(["format", "формат"]),
                .segmented(FixtureKeys.mode, L10n("Compatibility", "Совместимость"),
                           [FieldOption("best", L10n("Best for Apple", "Лучше для Apple")), FieldOption("max", L10n("Maximum quality", "Максимальное качество")),
                            FieldOption("universal", L10n("Universal", "Универсальный"))], def: "best").basic().oracle("mode"),
                .toggle(FixtureKeys.fast, L10n("Optimize for streaming", "Оптимизировать для потоковой передачи"), def: true)
                    .basic().visible(.in(FixtureKeys.container, ["mp4", "mov"])).oracle("fast")
                    .help(L10n("Puts the index at the start of the file.", "Индекс переносится в начало файла."))
            ]),
            .make("video", L10n("Video", "Видео"), [
                .slider(FixtureKeys.quality, L10n("Quality", "Качество"), min: 0, max: 51, def: 23, unit: "CRF",
                        minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                    .basic().oracle("quality").aliases(["crf", "качество"])
                    .rule(.warning("quality.high", when: .gt(FixtureKeys.quality, 40), L10n("This quality loses a lot of detail. The typical range is 18 to 30.", "При таком качестве теряется много деталей. Обычный диапазон - от 18 до 30."),
                                   field: FixtureKeys.quality, fix: OptionFix(title: L10n("Use 30", "Взять 30"), set: [FixtureKeys.quality: 30]))),
                .picker(FixtureKeys.rc, L10n("Rate control", "Управление битрейтом"), [FieldOption("cq", L10n("Constant quality", "Постоянное качество")), FieldOption("abr", L10n("Average bitrate", "Средний битрейт"))], def: "cq")
                    .standard().oracle("rc"),
                .slider(FixtureKeys.bitrate, L10n("Bitrate", "Битрейт"), min: 100, max: 20000, step: 50, def: 4000, unit: "kbit/s", logarithmic: true)
                    .standard().enabled(.eq(FixtureKeys.rc, "abr"), reason: L10n("Average bitrate is off. Choose it in Rate control.", "Средний битрейт выключен. Выберите его в «Управлении битрейтом».")).oracle("bitrate").aliases(["битрейт", "bitrate"]),
                .picker(FixtureKeys.limit, L10n("Resolution limit", "Ограничение разрешения"), [FieldOption("720", "720p"), FieldOption("1080", "1080p"), FieldOption("2160", "2160p")], def: "1080")
                    .defaultFromSource(.string("1080")) { src in
                        guard let h = src?.int("video.height") else { return nil }
                        return .string(h >= 2160 ? "2160" : (h >= 1080 ? "1080" : "720"))
                    }.basic().oracle("limit"),
                .stepper(FixtureKeys.refs, L10n("Reference frames", "Опорные кадры"), min: 1, max: 16, def: 3).expert().oracle("refs"),
                .number(FixtureKeys.maxrate, L10n("Peak bitrate", "Пиковый битрейт"), min: 0, max: 100000, step: 1, def: 0, unit: "kbit/s").standard().oracle("maxrate"),
                .toggle(FixtureKeys.gated, L10n("Hardware boost", "Аппаратное ускорение"), def: false)
                    .needs(["tool.nonexistent"], reason: L10n("Needs a tool that is not installed.", "Нужна утилита, которая не установлена.")).standard().oracle("gated")
            ]),
            .make("trim", L10n("Trim", "Обрезка"), [
                .time(FixtureKeys.trimStart, L10n("Start", "Начало")).basic().oracle("trim.start"),
                .time(FixtureKeys.trimEnd, L10n("End", "Конец")).basic().oracle("trim.end")
            ]),
            .make("meta", L10n("Metadata", "Метаданные"), level: .standard, collapsed: true, [
                .text(FixtureKeys.title, L10n("Title", "Название"), placeholder: L10n("Untitled", "Без названия")).standard().oracle("title"),
                .text(FixtureKeys.comment, L10n("Comment", "Комментарий"), multiline: true).expert().oracle("comment"),
                .text(FixtureKeys.password, L10n("Password", "Пароль"), secure: true).standard().oracle("password"),
                .color(FixtureKeys.bg, L10n("Background color", "Цвет фона"), def: "#000000").standard().oracle("bg"),
                .folder(FixtureKeys.outdir, L10n("Extra folder", "Дополнительная папка")).standard().oracle("outdir"),
                .file(FixtureKeys.cover, L10n("Cover image", "Обложка")).standard().oracle("cover")
            ]),
            .make("audio", L10n("Audio tracks", "Аудиодорожки"), level: .standard, [
                .tracks(FixtureKeys.tracks, L10n("Tracks", "Дорожки"),
                        TrackSpec(columns: audioColumns, maxRows: 4, rowTitleKey: "title", addTitle: L10n("Add Audio Track", "Добавить аудиодорожку")),
                        defaultRows: { src in
                            (src?.streams(of: .audio) ?? []).map { ["source": .int($0.index), "codec": .string("aac"), "bitrate": .int(160), "lang": .string($0.language ?? ""), "title": .string($0.title)] }
                        }).standard().oracle("audio.tracks")
            ])
        ])
        let extra = OptionPage.make("extra", symbol: "gearshape", L10n("More", "Дополнительно"), [
            .make("many", L10n("Many fields", "Много параметров"), (1...8).map { i in
                OptionField.toggle("extra.f\(i)", L10n("Extra option \(i)", "Доп. параметр \(i)"), def: false).basic().oracle("extra.f\(i)")
            }),
            .make("second", L10n("Second group", "Вторая группа"), [OptionField.toggle("extra.s1", L10n("Second \u{2013} one", "Вторая \u{2013} первый"), def: true).basic().oracle("extra.s1")]),
            .make("third", L10n("Third group", "Третья группа"), [OptionField.toggle("extra.t1", L10n("Third \u{2013} one", "Третья \u{2013} первый"), def: true).basic().oracle("extra.t1")]),
            .make("expert", L10n("Expert only", "Только для экспертов"), level: .expert, [
                OptionField.text("extra.x264", L10n("Encoder parameters", "Параметры кодировщика"), def: "").expert().aliases(["x264", "параметры"]).oracle("extra.x264")
            ])
        ])
        let locked = OptionPage.make("needs", symbol: "lock", L10n("Needs a tool", "Нужна утилита"), requires: ["tool.nonexistent"], [
            .make("n", [OptionField.toggle("needs.t", L10n("Locked option", "Недоступный параметр"), def: false).basic().oracle("needs.t")])
        ])
        var s = OptionSchema(id: schemaID, title: L10n("Studio test", "Тест студии"), symbol: "film", pages: [main, extra, locked])
        s.rules = [.info("schema.note", when: .eq(FixtureKeys.mode, "universal"), L10n("Universal mode plays everywhere but is larger.", "Универсальный режим воспроизводится везде, но файл больше."))]
        return s
    }

    /// Every FieldKind case exists at least once in `schema()` (checked by a test).
    static func kindName(_ k: FieldKind) -> String {
        switch k {
        case .toggle: return "toggle"; case .picker: return "picker"; case .segmented: return "segmented"; case .slider: return "slider"
        case .stepper: return "stepper"; case .text: return "text"; case .time: return "time"; case .number: return "number"
        case .folder: return "folder"; case .file: return "file"; case .color: return "color"; case .tracks: return "tracks"
        }
    }
    static let allKindNames: Set<String> = ["toggle", "picker", "segmented", "slider", "stepper", "text", "time", "number", "folder", "file", "color", "tracks"]

    /// A realistic probed source: 4K video with two audio streams.
    static func sourceInfo(for url: URL, kind: FileKind = .other) -> SourceInfo {
        var info = SourceInfo(url: url, kind: kind)
        info.facts = ["container": "mov", "duration": .double(125.5), "size": .double(412_000_000), "video.height": .int(2160), "video.width": .int(3840), "video.codec": "hevc",
                      "audio.count": .int(2)]
        info.chips = [SourceChip(symbol: "film", text: "MOV"), SourceChip(symbol: nil, text: "HEVC"), SourceChip(symbol: nil, text: "3840\u{00D7}2160"),
                      SourceChip(symbol: nil, text: "59,94 fps"), SourceChip(symbol: "clock", text: "2:05"), SourceChip(symbol: "internaldrive", text: "412 MB")]
        info.streams = [
            SourceStream(kind: .video, index: 0, title: "HEVC", detail: "3840\u{00D7}2160, 59,94 fps, 10-bit", language: nil, isDefault: true),
            SourceStream(kind: .audio, index: 1, title: "English", detail: "AAC, stereo, 160 kbit/s", language: "en", isDefault: true),
            SourceStream(kind: .audio, index: 2, title: "Русский", detail: "AC-3, 5.1, 384 kbit/s", language: "ru"),
            SourceStream(kind: .subtitle, index: 3, title: "English", detail: "SubRip", language: "en")
        ]
        info.warnings = [L10n("10-bit HDR", "10-битный HDR"), L10n("Variable frame rate", "Переменная частота кадров")]
        return info
    }
}

// MARK: - Fake operations

/// Per-file conversion that writes the resolved options (sorted JSON) next to the source: lets tests compare the quick path and the Studio path byte for byte.
final class FixtureConvertOp: PerFileOperation, @unchecked Sendable {
    let hooks: FixtureHooks
    let overrides: OptionValues

    init(id: String, label: String, overrides: OptionValues = OptionValues(), hooks: FixtureHooks = FixtureHooks()) {
        self.hooks = hooks
        self.overrides = overrides
        super.init(meta: .make(id, .convert, .video, L10n(label), symbol: "film", schema: StudioFixture.schemaID, suffix: L10n("fx"), anyFile: true))
    }

    override func optionSchema(for items: [FileItem]) -> OptionSchema { StudioFixture.schema() }
    override func quickOverrides(settings: SettingsData) -> OptionValues { overrides }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        let start = options[FixtureKeys.trimStart]?.asDouble ?? 0
        guard let end = options[FixtureKeys.trimEnd]?.asDouble, end > 0, end <= start else { return [] }
        return [OptionMessage(id: "V19", severity: .error, text: L10n("The end must come after the start.", "Конец должен быть позже начала."), fieldKey: FixtureKeys.trimEnd,
                              fix: OptionFix(title: L10n("Trim to the End of the File", "Обрезать до конца файла"), set: [FixtureKeys.trimEnd: .string("")]))]
    }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        hooks.estimateCalls.withLock { $0 += 1 }
        let q = options.int(FixtureKeys.quality, 23)
        let base = Int64(source?.sizeBytes ?? items.compactMap(\.size).reduce(0, +))
        return OperationEstimate(bytes: max(base > 0 ? base : 10_000_000, 1) * Int64(max(60 - q, 1)) / 120, seconds: 30, confidence: .rough)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        hooks.chipCalls.withLock { $0 += 1 }
        return [options.string(FixtureKeys.container, "mp4").uppercased(), "CRF \(options.int(FixtureKeys.quality, 23))", options.string(FixtureKeys.limit, "1080") + "p"]
    }

    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        hooks.previewStarted.withLock { $0 += 1 }
        let delay = hooks.previewDelay.value
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: delay) } catch { hooks.previewCancelled.withLock { $0 += 1 }; throw error }
        }
        hooks.previewFinished.withLock { $0 += 1 }
        return OperationPreview(before: nil, after: nil, note: nil, sampleOutputBytes: 4242 + Int64(options.int(FixtureKeys.quality, 0)))
    }

    /// The text every run writes: the complete resolved options as sorted JSON (secrets excluded like everywhere else).
    static func dump(_ options: OptionValues) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? String(data: enc.encode(options), encoding: .utf8)) ?? ""
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let text = Self.dump(ctx.options)
        let url = try await ctx.produceFile(for: item, suffix: meta.suffix, ext: "txt") { tmp in try text.write(to: tmp, atomically: false, encoding: .utf8) }
        progress.report(1)
        return [url]
    }
}

/// A batch operation (needs two files) with a tiny schema.
final class FixtureBatchOp: BatchOperation, @unchecked Sendable {
    init() { super.init(meta: .make("test.studio.merge", .tools, .app, L10n("Merge"), symbol: "rectangle.stack", schema: "test.studio.merge", min: 2, anyFile: true)) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: "test.studio.merge", title: L10n("Merge", "Объединить"), pages: [.make("m", symbol: "rectangle.stack", L10n("Merge", "Объединить"), [.make("g", [.toggle("gap", L10n("Add a gap"), def: false)])])])
    }
    override func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] { [] }
}

/// A link operation (a download mode) that does nothing and never touches the network.
final class FixtureLinkOp: LinkOperation, @unchecked Sendable {
    init() { super.init(meta: .link("test.studio.dl", L10n("Download"), symbol: "arrow.down.circle", schema: "test.studio.dl")) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema {
        OptionSchema(id: "test.studio.dl", title: L10n("Download", "Скачать"), pages: [.make("d", symbol: "arrow.down.circle", L10n("Download", "Скачать"),
                     [.make("g", [.picker("dl.mode", L10n("Mode"), [FieldOption("apple", "Best for Apple"), FieldOption("audio", "Audio only")], def: "apple")])])])
    }
    override func executeLinks(_ links: [LinkItem], ctx: OperationContext) async throws -> OperationResult { OperationResult(note: L10n("fixture")) }
}

/// Registers a probe for `.other` files that answers with `StudioFixture.sourceInfo` (once per process).
final class FixtureProbe: SourceProbe, @unchecked Sendable {
    nonisolated(unsafe) static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        SourceProbeRegistry.shared.register(kinds: [.other], probe: FixtureProbe())
    }
    func probe(_ item: FileItem) async -> SourceInfo {
        var info = StudioFixture.sourceInfo(for: item.url, kind: item.kind)
        info.facts["size"] = nil   // the registry fills the real size
        return info
    }
}

// MARK: - Harness

/// An isolated Studio environment: own registry (fixture operations), settings file, preset store, job runner, and a temp folder for inputs.
@MainActor
final class StudioHarness {
    let registry = OperationRegistry()
    let settings: AppSettings
    let presets: PresetStore
    let runner: JobRunner
    let hooks = FixtureHooks()
    let fx = TestFixtures(label: "studio")
    let opA: FixtureConvertOp
    let opB: FixtureConvertOp

    init() {
        settings = AppSettings(fileURL: fx.url("settings.json"), autosave: false)
        presets = PresetStore(directory: fx.root.appendingPathComponent("Presets"))
        runner = JobRunner(persistence: false, registry: registry, settings: settings)
        runner.maxConcurrentOverride = 2
        opA = FixtureConvertOp(id: "test.studio.a", label: "Convert A", hooks: hooks)
        opB = FixtureConvertOp(id: "test.studio.b", label: "Convert B", overrides: [FixtureKeys.quality: 28, FixtureKeys.container: "mov"], hooks: hooks)
        registry.register([opA, opB, FixtureBatchOp(), FixtureLinkOp()])
        FixtureProbe.install()
    }

    func cleanup() { fx.cleanup() }

    /// A small file of kind `.other` (the fixture probe answers for it).
    @discardableResult
    func file(_ name: String = "clip.stud", bytes: Int = 2048) throws -> FileItem {
        let url = fx.url(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return FileItem(url: url)
    }

    func session(files: [FileItem] = [], links: [LinkItem] = [], target: String? = nil, recipe: Recipe? = nil, autoProbe: Bool = false) -> StudioSession {
        StudioSession(input: IncomingInput(files: files, links: links), targetID: target, recipe: recipe, registry: registry, settings: settings,
                      presetStore: presets, runner: runner, autoProbe: autoProbe)
    }

    /// A session whose first source already carries the fixture probe (no background work).
    func probedSession(files: [FileItem], target: String? = StudioFixture.schemaID, operationID: String? = nil) -> StudioSession {
        let s = session(files: files, target: operationID ?? target)
        for src in s.sources { if let f = src.input.file { s.applyProbe(StudioFixture.sourceInfo(for: f.url), forSourceID: src.id) } }
        return s
    }
}
