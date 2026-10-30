import Foundation

// Pure text helpers of the download UI: durations, sizes, the chips of the info card, the names of qualities. No views, no state, no I/O, so every function is unit-tested
// and the views stay short.

enum DownloadFormatText {
    /// "12:34", "1:02:03"; nil when the length is unknown.
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0, seconds.isFinite else { return nil }
        return Util.formatTime(seconds)
    }

    /// "4K", "8K", "1440p", "720p": the name people use for a picture height.
    static func resolutionName(_ height: Int) -> String {
        switch height {
        case 4320...: return "8K"
        case 2160..<4320: return "4K"
        case 0: return L("Best available", "Лучшее доступное")
        default: return "\(height)p"
        }
    }

    /// "AV1", "VP9", "H.264", "HEVC"; nil for audio-only or unknown codecs.
    static func codecName(_ family: DownloadFormat.CodecFamily) -> String? {
        switch family {
        case .av1, .vp9, .h264, .hevc: return family.rawValue
        case .other, .none: return nil
        }
    }

    /// "30 fps" / "60 fps"; nil when unknown or the usual 24 to 30.
    static func fpsName(_ fps: Double?) -> String? {
        guard let fps, fps >= 31 else { return nil }
        return "\(Int(fps.rounded())) fps"
    }

    /// "120 MB" or "about 120 MB" (`approximate`); "Size unknown" when there is no estimate.
    static func size(_ bytes: Int64?, approximate: Bool = true) -> String {
        guard let bytes, bytes > 0 else { return L("Size unknown", "Размер неизвестен") }
        let text = Util.formatBytes(bytes)
        return approximate ? L("about \(text)", "около \(text)") : text
    }

    /// The short size for a table column: "~120 MB" or an em dash.
    static func sizeColumn(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "\u{2014}" }
        return "~" + Util.formatBytes(bytes)
    }

    /// Chips for the best quality the page offers: "4K", "60 fps", "AV1", "HDR". At most four, in that order.
    static func bestChips(for info: DownloadInfo) -> [String] {
        var chips: [String] = []
        if info.isLive { chips.append(L("Live", "Прямой эфир")) }
        let ladder = FormatSelector.qualityOptions(for: info)
        if let best = ladder.first {
            chips.append(resolutionName(best.height))
            if let fps = fpsName(best.fps) { chips.append(fps) }
            if let codec = codecName(best.codec) { chips.append(codec) }
            if best.isHDR { chips.append("HDR") }
        } else if !FormatSelector.playable(info).isEmpty, info.formats.allSatisfy(\.isAudioOnly) {
            chips.append(L("Audio only", "Только звук"))
        }
        return chips
    }

    /// Typical video bitrate (kbit/s) per picture height, used ONLY to estimate a playlist whose entries have no format list yet.
    static func typicalVideoKbps(height: Int) -> Double {
        switch height {
        case 4320...: return 45_000
        case 2160...: return 16_000
        case 1440...: return 9_000
        case 1080...: return 4_500
        case 720...: return 2_500
        case 480...: return 1_200
        case 360...: return 700
        default: return 400
        }
    }

    /// A rough size for `seconds` of video capped at `height` (0 = best, treated as 1080p) plus about 128 kbit/s of sound; audio only when `audioOnly`.
    static func roughBytes(seconds: Double, height: Int, audioOnly: Bool) -> Int64 {
        let kbps = audioOnly ? 128 : typicalVideoKbps(height: height == 0 ? 1080 : height) + 128
        return Int64(max(seconds, 0) * kbps * 1000 / 8)
    }

    /// "12 videos" / "12 видео".
    static func videoCount(_ n: Int) -> String {
        L(n == 1 ? "1 video" : "\(n) videos", "\(n) видео")   // "видео" does not decline
    }

    /// "3 of 12 selected" / "Выбрано 3 из 12".
    static func selected(_ n: Int, of total: Int) -> String { L("\(n) of \(total) selected", "Выбрано \(n) из \(total)") }
}
