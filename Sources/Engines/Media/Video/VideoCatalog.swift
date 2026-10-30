import Foundation

// 8 Convert + 7 Tools operations of the video family (spec/catalog.md 3.3) plus gif.to.mp4 / gif.to.webm (input GIF, listed after the image
// conversions on the wheel because EnginesBootstrap registers video after image). Transcodes are `.video` concurrency (one at a time).
// The quick recipes live in `VideoQuick` (VideoPresets.swift).

enum VideoCatalog {
    static let inputs = Formats.videoInputs

    @MainActor
    static func operations() -> [Operation] {
        var ops: [Operation] = []
        let convert: [(String, L10n?, String, [Tool])] = [("mp4", nil, "film", []), ("mov", nil, "film", []), ("mkv", nil, "film", [.ffmpeg]), ("webm", nil, "film", [.ffmpeg]),
                                                           ("gif", L10n("animation", "анимация"), "photo.on.rectangle", [.ffmpeg]), ("mp3", L10n("audio only", "только звук"), "waveform", [.ffmpeg])]
        for (key, sub, symbol, tools) in convert {
            ops.append(VideoOperation(.convert("video.to.\(key)", .video, to: key, sub: sub, symbol: symbol, schema: VideoSchemas.convertID, inputs: inputs, requires: tools, concurrency: .video)) { s in
                VideoQuick.convert(to: key, settings: s)
            })
        }
        for key in ["mp4", "webm"] {
            ops.append(VideoOperation(.convert("gif.to.\(key)", .video, to: key, sub: L10n("video", "видео"), symbol: "film", schema: VideoSchemas.convertID, inputs: ["gif"],
                                                requires: [.ffmpeg], concurrency: .video)) { s in VideoQuick.convert(to: key, settings: s) })
        }
        func tool(_ id: String, _ label: L10n, sub: L10n? = nil, symbol: String, suffix: L10n, prompts: [String] = [], passthrough: PassthroughKind = .none, quick: @escaping @Sendable (SettingsData) -> OptionValues) {
            ops.append(VideoOperation(.make(id, .tools, .video, label, sub: sub, symbol: symbol, schema: VideoSchemas.convertID, inputs: inputs, requires: [], suffix: suffix,
                                           concurrency: .video, prompts: prompts, passthrough: passthrough), quick: quick))
        }
        tool("video.compress", L10n("Compress", "Сжать"), sub: L10n("H.264"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("compressed", "сжато")) { VideoQuick.compress(settings: $0) }
        tool("video.720p", L10n("720p"), sub: L10n("downscale", "уменьшение"), symbol: "arrow.down.right.and.arrow.up.left", suffix: L10n("720p")) { VideoQuick.p720(settings: $0) }
        tool("video.mute", L10n("Mute", "Без звука"), sub: L10n("muted", "без звука"), symbol: "speaker.slash", suffix: L10n("muted", "без звука"), passthrough: .remux) { _ in VideoQuick.mute() }
        tool("video.trim", L10n("Trim", "Обрезать"), sub: L10n("start-end", "начало-конец"), symbol: "timer", suffix: L10n("trimmed", "обрезано"),
             prompts: [VideoKeys.trimStart, VideoKeys.trimEnd]) { VideoQuick.trim(settings: $0) }
        tool("video.rotate", L10n("Rotate", "Повернуть"), sub: L10n("right", "вправо"), symbol: "rotate.right", suffix: L10n("rotated", "повёрнуто")) { VideoQuick.rotate(settings: $0) }
        tool("video.speed2", L10n("Speed up", "Ускорить"), sub: L10n("2×"), symbol: "play.fill", suffix: L10n("2×")) { VideoQuick.speed2(settings: $0) }
        ops.append(VideoFramesOperation(meta: .make("video.thumbnail", .tools, .video, L10n("Thumbnail", "Миниатюра"), sub: L10n("PNG frame", "кадр PNG"), symbol: "camera", schema: VideoSchemas.framesID,
                                              inputs: inputs, requires: [], suffix: L10n("thumbnail", "миниатюра"), concurrency: .light)))
        // Join: two or more videos into one (natural order, lossless when the clips match, fitted to one format when they do not).
        ops.append(VideoJoinOperation(meta: .make("video.concat", .tools, .video, L10n("Join", "Объединить"), sub: L10n("2+ videos", "2+ видео"), symbol: "arrow.triangle.merge",
                                                  schema: VideoJoinSchema.id, inputs: inputs, requires: [.ffmpeg], suffix: L10n("joined", "объединено"), min: 2, concurrency: .video)))
        return ops
    }
}
