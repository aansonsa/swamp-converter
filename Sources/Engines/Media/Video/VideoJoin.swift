import Foundation

// video.concat: the Tools wheel's "Join" for two or more videos. Schema `video.join`, the operation, the run (probe, plan, one ffmpeg command, atomic output).
// Planning and argv live in VideoJoinPlan.swift.

enum VideoJoinSchema {
    static let id = "video.join"

    static func schema(items: [FileItem]) -> OptionSchema { cached }

    private static let cached: OptionSchema = {
        let format = OptionGroup.make("format", L10n("Result", "Результат"), [
            .picker(VideoJoinKeys.container, L10n("Format", "Формат"), [
                FieldOption("same", L10n("Same as the first video", "Как у первого видео")),
                FieldOption("mp4", "MP4"), FieldOption("mov", "MOV"), FieldOption("mkv", "MKV"),
                FieldOption("webm", "WebM", requires: ["ff.enc.libvpx-vp9"], hint: L10n("VP9 and Opus. Needs ffmpeg.", "VP9 и Opus. Нужен ffmpeg."))
            ], def: "same").basic()
                .help(L10n("MP4, MOV and MKV keep H.264 or HEVC; WebM always re-encodes to VP9.", "MP4, MOV и MKV подходят для H.264 и HEVC; WebM всегда перекодирует в VP9."))
                .oracle("vjoin.container"),
            .slider(VideoJoinKeys.quality, L10n("Quality when re-encoding", "Качество при перекодировании"), min: 14, max: 32, step: 1, def: 21,
                    minLabel: L10n("Better quality", "Лучше качество"), maxLabel: L10n("Smaller file", "Меньше файл")).standard()
                .help(L10n("Used only when the videos differ and have to be re-encoded. Videos that match are joined without any loss.", "Нужно только если ролики различаются и их приходится перекодировать. Одинаковые ролики склеиваются без потерь."))
                .oracle("vjoin.quality")
        ])
        let join = OptionGroup.make("join", L10n("Joining", "Склейка"), [
            .picker(VideoJoinKeys.order, L10n("Order", "Порядок"), [
                FieldOption("natural", L10n("By name (natural order)", "По имени (естественный порядок)")),
                FieldOption("selection", L10n("As selected", "Как выбрано"))
            ], def: "natural").basic()
                .help(L10n("Natural order puts clip2 before clip10.", "Естественный порядок ставит clip2 перед clip10."))
                .oracle("vjoin.order"),
            .toggle(VideoJoinKeys.normalise, L10n("Match the clips", "Привести ролики к одному формату"), def: true).standard()
                .help(L10n("Fits videos of different size, frame rate or sound to one format (letterboxed, never stretched). Off: only identical videos are joined, without any loss.",
                           "Приводит ролики с разным размером, частотой кадров или звуком к одному формату (с полями, без растяжения). Выключено: склеиваются только одинаковые ролики, без потерь."))
                .oracle("vjoin.normalise"),
            .picker(VideoJoinKeys.match, L10n("Match to", "Равняться на"), [
                FieldOption("best", L10n("The largest picture and highest frame rate", "Самый большой кадр и самую высокую частоту")),
                FieldOption("first", L10n("The first video", "Первое видео"))
            ], def: "best").standard()
                .visible(.eq(VideoJoinKeys.normalise, true))
                .oracle("vjoin.match"),
            .toggle(VideoJoinKeys.keepMeta, L10n("Keep the first video’s tags", "Сохранить теги первого видео"), def: true).standard()
                .help(L10n("Title, date and location of the first video. Turn off to remove them.", "Название, дата и место съёмки первого видео. Выключите, чтобы убрать."))
                .oracle("vjoin.keepMeta")
        ])
        return OptionSchema(id: id, title: L10n("Join videos", "Склейка видео"), symbol: "arrow.triangle.merge",
                            pages: [OptionPage.make("join", symbol: "arrow.triangle.merge", L10n("Join", "Склейка"), [format, join])])
    }()
}

/// Joins two or more videos into one file named after the first (sorted) video: `{name} (joined).{ext}`.
final class VideoJoinOperation: BatchOperation, @unchecked Sendable {
    override func quickOverrides(settings: SettingsData) -> OptionValues { [VideoJoinKeys.quality: .int(settings.quality.videoCrf)] }
    override func optionSchema(for items: [FileItem]) -> OptionSchema { VideoJoinSchema.schema(items: items) }
    override func privacyOverrides() -> OptionValues { [VideoJoinKeys.keepMeta: false] }

    override func estimate(options: OptionValues, items: [FileItem], source: SourceInfo?) -> OperationEstimate? {
        let total = items.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.size] as? NSNumber)?.int64Value ?? 0) }
        return total > 0 ? OperationEstimate(bytes: total, seconds: nil, confidence: .rough, note: L10n("About the sum of the videos.", "Примерно сумма размеров роликов.")) : nil
    }

    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        try ctx.checkCancelled()
        let natural = ctx.options.string(VideoJoinKeys.order, "natural") != "selection"
        let ordered = VideoJoinPlanner.ordered(items, natural: natural)
        var clips: [VideoJoinClip] = []
        for item in ordered {
            try ctx.checkCancelled()
            do { clips.append(VideoJoinClip(url: item.url, info: try await VideoMediaCache.shared.info(for: item.url, tools: ctx.tools))) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ConversionError.fileUnreadable(item.url) }
        }
        let toolset = VideoJob.toolset(for: ctx)
        guard toolset.hasFFmpeg else { throw ConversionError.toolMissing(.ffmpeg) }
        let plan = try VideoJoinPlanner.plan(clips: clips, options: ctx.options, toolset: toolset)
        for n in plan.notes { ctx.log("note: \(n.en)") }
        ctx.log("join route: \(plan.route.rawValue), \(plan.clips.count) clips, \(plan.container)" + (plan.route == .reencode ? ", \(plan.width)x\(plan.height) @ \(plan.fps)" : ""))
        let keepMeta = ctx.options.bool(VideoJoinKeys.keepMeta, true)
        // The naming rule: beside the first SORTED video, whatever the order of joining is.
        let namer = VideoJoinPlanner.ordered(items, natural: true)[0]
        let url = try await ctx.produceFile(for: namer, suffix: meta.suffix, ext: plan.container) { part in
            let temp = ctx.tempDir.appendingPathComponent("join-\(Util.hex8())", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let cmd = try VideoJoinArgs.command(plan, output: part, tempDirectory: temp, keepMeta: keepMeta)
            ctx.log(cmd.displayString())
            try await ctx.waitIfPaused()
            try await FFmpegRunner.run(cmd, ctx: ctx, totalDuration: plan.totalDuration)
        }
        ctx.report(1)
        var result = OperationResult(outputs: [url])
        if !plan.notes.isEmpty { result.note = L10n(plan.notes.map(\.en).joined(separator: " "), plan.notes.map(\.ru).joined(separator: " ")) }
        return result
    }
}
