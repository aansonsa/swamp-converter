import Foundation
import CoreGraphics

// The Operation protocol: one wheel slice AND one Studio target. Engines subclass PerFileOperation / BatchOperation
// (or AppAction in the Actions module) and register instances in OperationRegistry.
//
// THE KEY RULE ("two speeds, one engine"):
//   * An operation's behaviour is a pure function of (items, ctx.options). It NEVER branches on its own id.
//   * Several operations may share one schema id (e.g. image.to.jpg, image.to.png, image.compress, image.half all use
//     "image.convert"); they differ only by `quickOverrides` (the quick recipe), label and wheel placement.
//   * Studio runs the same operation with options the user edited; the result must be byte-identical to the quick path
//     when the options are equal.
//   * Every option declared in the schema MUST have a real effect on the output, proven by an oracle self-test.

enum RunMode: String, Codable, Sendable {
    /// Wheel, Services, Dock/menu-bar drop, hotkey: options = the operation's quick recipe.
    case quick
    /// Studio / queue: options edited by the user.
    case studio
    /// Watched folders and chains: like quick, but unattended (no dialogs, nothing remembered, nothing revealed).
    case automatic
}

enum ConcurrencyClass: String, Codable, Sendable {
    /// Many may run at once (images, PDFs, documents, audio).
    case light
    /// Software video encoders: one at a time (they use all cores).
    case video
    /// Runs alone (LibreOffice instance, whole-disk operations).
    case exclusive
}

/// Static description of an operation (everything the wheel and Studio need without running anything).
struct OperationMeta: Sendable {
    /// Stable dotted id: "image.to.jpg", "video.compress", "pdf.merge", "action.copy", "preset.<id>".
    var id: String
    var wheel: WheelKind
    var family: OperationFamily
    var label: L10n
    var subtitle: L10n? = nil
    /// SF Symbol (must exist in the macOS 26 symbol set).
    var symbol: String
    /// Studio target id (= OptionSchema.id). Operations with the same schemaID share one set of option pages.
    var schemaID: String
    /// Required tools. A missing one makes the operation unavailable (shown disabled with the install hint).
    var requires: [Tool] = []
    /// Convert operations: the format key this slice produces ("jpg"). Quick runs skip files already in this format.
    var targetFormat: String? = nil
    /// Accepted input format keys; nil = any file (use with `acceptsAnyFile`).
    var inputs: Set<String>? = nil
    var acceptsDirectories = false
    var acceptsAnyFile = false
    /// Batch operations need at least this many items (merge/join = 2).
    var minItems = 1
    /// Keys of option fields the QUICK path asks before running, in a small sheet (trim start/end). Everything else
    /// comes from the quick recipe. Empty for almost every operation.
    var quickPromptKeys: [String] = []
    /// Localised suffix for `{name} ({suffix}).{ext}` naming of tools ("compressed" / "сжато"). Nil for conversions.
    var suffix: L10n? = nil
    var concurrency: ConcurrencyClass = .light
    /// Hidden from the wheels; reachable only as a Studio target (pdf.protect, image stamping ...).
    var studioOnly = false
    /// Actions run in the app, show no progress card and are never offered for watched folders.
    var isAppAction = false
    /// Link operations (downloads) accept `LinkItem`s instead of files; their wheel is `.link`.
    var acceptsLinks = false
    /// Nothing in this operation may touch the network unless it says so. Only the downloader's operations set this; the CLI,
    /// the job log and the Settings > Privacy page list operations that do.
    var usesNetwork = false
    /// Does the operation ever hand the input's bytes (or streams) through unchanged? Everything is `.none` by default: a conversion
    /// that merely renames, copies or wraps its input is a DEFECT, and the `conformance.*` self-tests fail it. Declare the exception here
    /// so the tests expect it (see `PassthroughKind`).
    var passthrough: PassthroughKind = .none
}

/// How an operation may relate its output to its input without decoding and re-encoding.
enum PassthroughKind: String, Codable, Sendable {
    /// A real transformation: the output is decoded from the input and encoded by a codec or serializer of the target format.
    case none
    /// Lossless stream copy into another container (video mute, MKV to MP4 with copied streams). The conformance tests demand: a different
    /// container, identical codecs, and every sample of every copied stream equal to the source.
    case remux
    /// The output may be byte-identical to the input (copy to a folder, "already in the right format" shortcut).
    case identity
    /// Depends on the input (Best for Apple remuxes what is already Apple-friendly and transcodes the rest); the tests check the planner's
    /// own claim (`remux` or `transcode`) against what the file contains.
    case conditional
}

enum OperationAvailability: Sendable {
    case available
    /// Shown dimmed / disabled. `reason` is the calm explanation ("Needs ffmpeg ... "), `missing` the tools involved.
    case unavailable(reason: L10n, missing: [Tool])

    var isAvailable: Bool { if case .available = self { return true } else { return false } }
    var reason: L10n? { if case .unavailable(let r, _) = self { return r } else { return nil } }
}

struct OperationEstimate: Sendable {
    enum Confidence: String, Sendable { case rough, sampled, measured }
    var bytes: Int64? = nil
    var seconds: Double? = nil
    var confidence: Confidence = .rough
    var note: L10n? = nil
}

/// What Studio shows in the preview pane.
struct OperationPreview: @unchecked Sendable {
    var before: CGImage?
    var after: CGImage?
    /// Explains an approximation ("Preview shows the first frame only").
    var note: L10n? = nil
    /// Size of the real result when it was measured on the sample (bytes), for the estimate.
    var sampleOutputBytes: Int64? = nil
}

struct OperationResult: Sendable {
    var outputs: [URL] = []
    /// Shown on the finished card ("The text is also on the clipboard.").
    var note: L10n? = nil
    /// Batch failures "name: message" when some files worked (the card becomes a warning).
    var failures: [String] = []
    var warnings: [String] = []
}

protocol Operation: AnyObject, Sendable {
    var meta: OperationMeta { get }

    /// Sparse option overrides that make this operation what it is (its quick recipe), computed from current settings
    /// (e.g. JPEG quality from `settings.quality.jpegQuality`).
    func quickOverrides(settings: SettingsData) -> OptionValues

    /// The option pages of this operation's target. MUST work for an empty `items` array. Do not include the Output page
    /// (Core appends it, see `studioSchema`).
    func optionSchema(for items: [FileItem]) -> OptionSchema

    /// Does the wheel offer this operation for `items`? (all-or-nothing, same-format hiding for conversions)
    func appliesTo(_ items: [FileItem]) -> Bool
    /// Does Studio offer this operation's target for `items`? (no same-format hiding)
    func appliesInStudio(_ items: [FileItem]) -> Bool
    func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability

    /// Operation-specific cross-field checks on top of the schema rules.
    func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage]
    /// Output size / time estimate for the Studio summary bar (nil = unknown). MUST be cheap (a few milliseconds, no encoding, no I/O beyond the probe the caller
    /// already holds): `JobRunner` also calls it before every file job for the free-disk-space preflight. Expensive measurements belong to an explicit "Measure" action.
    func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate?
    /// Short chips for the summary capsule ("MP4", "H.264", "1080p30", "CRF 22").
    func summaryChips(options: OptionValues, source: SourceInfo?) -> [String]

    /// Optional Studio preview: the source and the result of running these options on a small sample (image before/after,
    /// video frame at `time`). Return nil when the operation has no meaningful preview. Must be cheap (< 1 s typical),
    /// must never write next to the user's files (use `AppPaths.makeTempDirectory`) and must honour Task cancellation.
    func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview?

    func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult

    // MARK: Links and stages (additive API: every operation has working defaults in OperationBase)

    /// Link operations: does the link wheel / Studio offer this operation for `links`? File operations return false.
    func appliesToLinks(_ links: [LinkItem]) -> Bool
    /// Link operations: run on the links (download, then optional post-processing stages). File operations throw `unsupported`.
    func executeLinks(_ links: [LinkItem], ctx: OperationContext) async throws -> OperationResult
    /// Rough output size for links (known only after the info fetch; nil before). Used by the disk-space preflight.
    func estimateLinks(options: OptionValues, links: [LinkItem]) -> OperationEstimate?
    /// The stages this run will go through, in order (empty = one implicit stage). Depends on options, e.g. "convert" only
    /// exists when the after-download action is not "keep original".
    func stagePlan(options: OptionValues) -> [StageSpec]
    /// Sparse option overrides that remove location / camera metadata (the "always strip metadata" setting layers them into
    /// QUICK and AUTOMATIC runs). Return the engine's own strip values, e.g. [ImageKeys.mdMode: "strip"]; empty if not applicable.
    func privacyOverrides() -> OptionValues
}

extension Operation {
    var id: String { meta.id }
    var label: L10n { meta.label }
    var wheel: WheelKind { meta.wheel }

    /// Schema with the Output page appended: what the Quick sheet and Studio actually render.
    func studioSchema(for items: [FileItem]) -> OptionSchema { optionSchema(for: items).withOutputPage() }

    /// "Convert to X" for Convert operations whose label is an all-caps format tile; otherwise the label.
    var jobTitle: String {
        if meta.wheel == .convert, let t = meta.targetFormat {
            return L("Convert to \(Formats.displayName(t))", "Конвертация в \(Formats.displayName(t))")
        }
        return meta.label.text
    }
}

/// Shared default behaviour. Subclass PerFileOperation / BatchOperation / AppAction rather than this.
class OperationBase: Operation, @unchecked Sendable {
    let meta: OperationMeta

    init(meta: OperationMeta) { self.meta = meta }

    func quickOverrides(settings: SettingsData) -> OptionValues { OptionValues() }

    func optionSchema(for items: [FileItem]) -> OptionSchema { OptionSchema.empty(id: meta.schemaID, title: meta.label) }

    /// Are all items acceptable inputs (folders only when allowed)?
    func acceptsAll(_ items: [FileItem]) -> Bool {
        guard !items.isEmpty else { return false }
        for it in items {
            if it.isDirectory { if !meta.acceptsDirectories { return false }; continue }
            if meta.acceptsAnyFile { continue }
            guard let inputs = meta.inputs, inputs.contains(it.key) else { return false }
        }
        return true
    }

    func appliesTo(_ items: [FileItem]) -> Bool { acceptsAll(items) && items.count >= meta.minItems }
    func appliesInStudio(_ items: [FileItem]) -> Bool { acceptsAll(items) && items.count >= meta.minItems }

    func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        let missing = tools.missing(meta.requires)
        guard let first = missing.first else { return .available }
        return .unavailable(reason: Capabilities.reason(for: "tool.\(first.rawValue)"), missing: missing)
    }

    func appliesToLinks(_ links: [LinkItem]) -> Bool { false }
    func executeLinks(_ links: [LinkItem], ctx: OperationContext) async throws -> OperationResult {
        throw ConversionError.unsupported(L10n("This operation does not work with links.", "Эта операция не работает со ссылками."))
    }
    func estimateLinks(options: OptionValues, links: [LinkItem]) -> OperationEstimate? { nil }
    func stagePlan(options: OptionValues) -> [StageSpec] { [] }
    func privacyOverrides() -> OptionValues { OptionValues() }

    func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] { [] }
    func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? { nil }
    func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? { nil }
    func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] { [] }

    func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        throw ConversionError.unsupported(L10n("This operation is not implemented yet.", "Эта операция ещё не реализована."))
    }
}

/// One dropped file at a time, each independently (convert, compress, rotate...).
/// Failure policy (spec/catalog.md 2.0): with several files a failing file is recorded as "name: message" and the loop
/// continues; with all failing an aggregate error is thrown; a single file fails hard. Cancellation propagates at once.
class PerFileOperation: OperationBase, @unchecked Sendable {
    override func appliesTo(_ items: [FileItem]) -> Bool {
        guard acceptsAll(items), items.count >= meta.minItems else { return false }
        if let target = meta.targetFormat { return items.contains { $0.key != target } }   // hide when every file already has the format
        return true
    }

    /// Quick runs skip files that already are in the target format ([png, png, jpg] + "PNG" converts only the jpg).
    func shouldSkip(_ item: FileItem, ctx: OperationContext) -> Bool {
        ctx.mode != .studio && meta.targetFormat != nil && item.key == meta.targetFormat
    }

    /// Implement: process ONE item, return the produced files/folders. Use `ctx.produceFile` for atomic output,
    /// `progress.report(0...1)` for progress, `try await ctx.waitIfPaused()` / `try ctx.checkCancelled()` in long loops.
    func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        throw ConversionError.unsupported(L10n("This operation is not implemented yet.", "Эта операция ещё не реализована."))
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        let work = items.filter { !shouldSkip($0, ctx: ctx) }
        var result = OperationResult()
        if work.isEmpty { return result }
        var failures: [String] = []
        var missing: [Tool] = []
        for (i, item) in work.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            ctx.setCurrentItem(item, index: i, count: work.count)
            do {
                result.outputs += try await process(item, ctx: ctx, progress: ctx.slice(index: i, count: work.count))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if work.count == 1 { throw error }
                if case ConversionError.toolMissing(let tool) = error { missing.append(tool) }
                failures.append("\(item.name): \(ConversionError.describe(error))")
                ctx.log("FAILED \(item.name): \(ConversionError.describe(error))")
            }
        }
        ctx.report(1)
        if result.outputs.isEmpty && !failures.isEmpty {
            // Every file failed for the same reason, a program that is not installed: say that once, as itself, instead of one line per file.
            if missing.count == failures.count, let first = missing.first, missing.allSatisfy({ $0 == first }) { throw ConversionError.toolMissing(first) }
            throw ConversionError.aggregate(failures)
        }
        result.failures = failures
        return result
    }
}

/// All items together produce one result (merge, join, pack).
class BatchOperation: OperationBase, @unchecked Sendable {
    /// Implement: process all items, return the produced files.
    func process(_ items: [FileItem], ctx: OperationContext) async throws -> [URL] {
        throw ConversionError.unsupported(L10n("This operation is not implemented yet.", "Эта операция ещё не реализована."))
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        try ctx.checkCancelled()
        let outs = try await process(items, ctx: ctx)
        ctx.report(1)
        return OperationResult(outputs: outs)
    }
}

/// Base class of the operations on the LINK wheel (downloads). Subclass, override `executeLinks`, `stagePlan` and `optionSchema`.
/// A link operation is a normal Operation: it has a schema (Studio shows its options), a quick recipe and appears in the registry;
/// it simply takes links instead of files. `meta.usesNetwork` is forced on.
class LinkOperation: OperationBase, @unchecked Sendable {
    override init(meta: OperationMeta) {
        var m = meta
        m.wheel = .link
        m.family = .download
        m.acceptsLinks = true
        m.usesNetwork = true
        super.init(meta: m)
    }

    override func appliesTo(_ items: [FileItem]) -> Bool { false }
    override func appliesInStudio(_ items: [FileItem]) -> Bool { false }
    /// Default: at least one link and every link passes `LinkParsing`.
    override func appliesToLinks(_ links: [LinkItem]) -> Bool { !links.isEmpty && links.allSatisfy { LinkParsing.isDownloadable($0.url) } }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        throw ConversionError.unsupported(L10n("This operation works with links, not files.", "Эта операция работает со ссылками, а не с файлами."))
    }
}
