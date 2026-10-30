import Foundation

/// Live numbers for the Studio summary bar ("about 24.8 MB, fits Discord"). Cheap, no encoding unless the caller asks for a sample.
enum SizeEstimator {
    /// The limit chosen in `options`, in bytes (nil when a custom size is missing or invalid).
    static func targetBytes(_ options: OptionValues) -> Int64? {
        SizeTargetCatalog.bytes(forID: options.string(FitKeys.target, FitSchemas.defaultTarget), customMB: options.double(FitKeys.customMB, 10))
    }

    /// Expected size and time. The size is the limit itself minus the aim (the engines land between 95 and 100% of it), lowered where the content
    /// cannot fill it (a short clip at full quality, a recording at the top bitrate) and replaced by the real size when the file already fits.
    /// Time is a rough rule of thumb from the clip length / picture size; `confidence` is `.rough`.
    static func estimate(kind: FileKind, options: OptionValues, source: SourceInfo?) -> OperationEstimate? {
        guard let fit = FitKind(fileKind: kind), let target = targetBytes(options) else { return nil }
        if let s = source?.sizeBytes, s > 0, s <= target {
            return OperationEstimate(bytes: s, seconds: 0.5, confidence: .measured, note: FitMessages.alreadySmall)
        }
        var bytes = Int64(Double(target) * FitTuning.aimFraction)
        var seconds: Double?
        var note: L10n?
        switch fit {
        case .video:
            if let d = source?.duration, d > 0, let w = source?.int("video.width"), let h = source?.int("video.height") {
                let rotated = abs(source?.int("video.rotation") ?? 0) % 180 == 90
                let fps = source?.number("video.fps") ?? 30
                let plan = VideoFit.plan(durationSeconds: d, targetBytes: target, audioKbps: options.int(FitKeys.audioKbps, 96), sourceWidth: rotated ? h : w,
                                         sourceHeight: rotated ? w : h, sourceFPS: fps, hasAudio: (source?.int("audio.count") ?? 1) > 0,
                                         allowDownscale: options.bool(FitKeys.allowDownscale, true), preferTwoPass: options.bool(FitKeys.twoPass, true))
                if plan.unreachable { note = plan.notes.first } else {
                    bytes = min(bytes, VideoFit.expectedBytes(videoKbps: plan.videoKbps, audioKbps: plan.audioKbps, durationSeconds: d))
                    note = plan.notes.first
                }
                let pixelsPerSecond = Double(w * h) * max(fps, 1)
                let speed = min(max(80_000_000 / pixelsPerSecond, 0.3), 20)   // x264 medium on an M-series Mac, as multiples of real time
                seconds = d / speed * (plan.twoPass ? 1.8 : 1) + 1
            }
        case .audio:
            if let d = source?.duration, d > 0 {
                let codec = AudioFitCodec(name: options.string(FitKeys.audioCodec, "auto")).rawValue
                let kbps = AudioFit.bitrateKbps(durationSeconds: d, targetBytes: target, codec: codec)
                bytes = min(bytes, AudioFit.expectedBytes(kbps: kbps, durationSeconds: d, codec: codec))
                seconds = d / 150 + 0.5
            }
        case .image:
            if let w = source?.int("image.width"), let h = source?.int("image.height") {
                seconds = 0.4 + Double(w * h) / 12_000_000 * 1.6   // about eight probes of a 12-megapixel picture
            }
        case .pdf:
            seconds = 1 + Double(source?.int("pdf.pages") ?? 5) * 0.05 * 6
        }
        return OperationEstimate(bytes: bytes, seconds: seconds, confidence: .rough, note: note)
    }

    /// "Fits WhatsApp (16 MB)" / "About 3 MB over Discord (25 MB)" for the chip next to the estimate.
    static func verdict(estimatedBytes: Int64, target: SizeTarget) -> L10n {
        if estimatedBytes <= target.bytes {
            return L10n("Fits \(target.label.en)", "Подходит для \(target.label.ru)")
        }
        let over = Util.formatBytes(estimatedBytes - target.bytes)
        return L10n("About \(over) over \(target.label.en)", "На \(over) больше лимита \(target.label.ru)")
    }
}
