import Foundation
import CoreGraphics

/// All per-file video operations (convert, compress, 720p, mute, trim, rotate, speed, gif -> video). Behaviour = f(items, ctx.options): the operation
/// never looks at its own id; the quick recipes in `VideoQuick` are just sparse option overrides over the one `video.convert` schema.
final class VideoOperation: PerFileOperation, @unchecked Sendable {
    private let quick: @Sendable (SettingsData) -> OptionValues

    init(_ meta: OperationMeta, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
        self.quick = quick
        super.init(meta: meta)
    }

    override func quickOverrides(settings: SettingsData) -> OptionValues { quick(settings) }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { VideoSchemas.convert(items: items) }

    /// "Always strip metadata" layers this over quick and automatic runs: location, camera and creation tags go (spec: md.mode = strip).
    override func privacyOverrides() -> OptionValues { [VideoKeys.metadataMode: "strip"] }

    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        Self.availability(base: super.availability(for: items, tools: tools), items: items, hasFFmpeg: tools.has(.ffmpeg))
    }

    /// Without ffmpeg only what AVFoundation can open is possible (spec/backends.md fact 4): MP4 / MOV family sources.
    static func availability(base: OperationAvailability, items: [FileItem], hasFFmpeg: Bool) -> OperationAvailability {
        guard base.isAvailable, !hasFFmpeg else { return base }
        let native: Set<String> = ["mp4", "mov", "m4v", "3gp", "3g2"]
        if items.allSatisfy({ native.contains($0.key) }) { return .available }
        return .unavailable(reason: Capabilities.reason(for: "tool.ffmpeg"), missing: [.ffmpeg])
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let info = try await VideoMediaCache.shared.info(for: item.url, tools: ctx.tools)
        let job = VideoJob(item: item, info: info, ctx: ctx, progress: progress, toolset: VideoJob.toolset(for: ctx), suffix: meta.suffix)
        return try await job.run()
    }

    /// Plan notes (calm information) and warnings (cut moved to a key frame, size slightly over) travel to the finished card.
    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        var result: OperationResult
        do { result = try await super.execute(items: items, ctx: ctx) } catch { _ = VideoJobNotes.shared.take(ctx.jobID); throw error }
        let extra = VideoJobNotes.shared.take(ctx.jobID)
        result.warnings += extra.warnings.map(\.text)
        if !extra.notes.isEmpty {
            let uniq = extra.notes.reduce(into: [L10n]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3)
            result.note = L10n(uniq.map(\.en).joined(separator: " "), uniq.map(\.ru).joined(separator: " "))
        }
        return result
    }

    // MARK: Studio support

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] { VideoValidation.messages(options: options, source: source) }

    /// Size / time estimate for the Studio summary bar (spec/handbrake.md 2.14). Cheap: arithmetic over the plan, no encoding.
    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        VideoEstimator.estimate(options: options, source: source)
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] { VideoEstimator.chips(options: options, source: source) }

    /// Frame at `time` with the current filters applied (before = the untouched frame).
    override func preview(items: [FileItem], options: OptionValues, source: SourceInfo?, time: Double?, maxPixel: Int) async throws -> OperationPreview? {
        guard let item = items.first else { return nil }
        return try await VideoPreview.make(item: item, options: options, source: source, time: time, maxPixel: maxPixel)
    }
}

/// Small cache so the Studio's repeated previews and estimates do not probe the same file again and again.
final class VideoMediaCache: @unchecked Sendable {
    static let shared = VideoMediaCache()
    private let store = Locked<(entries: [String: MediaInfo], order: [String])>(([:], []))

    private func key(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.path)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((a?[.size] as? NSNumber)?.int64Value ?? 0)"
    }

    func info(for url: URL, tools: ToolLocator = .shared) async throws -> MediaInfo {
        let k = key(url)
        if let hit = store.value.entries[k] { return hit }
        let info = try await MediaProbe.probe(url, tools: tools)
        store.withLock { s in
            s.entries[k] = info; s.order.append(k)
            if s.order.count > 8 { s.entries[s.order.removeFirst()] = nil }
        }
        return info
    }
}

struct VideoSourceProbe: SourceProbe {
    /// `MediaProbe.probe` + `MediaProbe.sourceInfo`. Never throws: an unreadable file returns the bare record with an explanation.
    func probe(_ item: FileItem) async -> SourceInfo {
        do {
            let info = try await VideoMediaCache.shared.info(for: item.url)
            return MediaProbe.sourceInfo(from: info, kind: item.kind)
        } catch {
            var s = SourceInfo(url: item.url, kind: item.kind)
            s.warnings.append(L10n("This file could not be read. It may be damaged or in a format this Mac cannot open.", "Не удалось прочитать файл. Возможно, он повреждён или в формате, который этот Mac не открывает."))
            return s
        }
    }
}
