import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import VideoToolbox

// The no-ffmpeg route (spec/handbrake.md 2.15, 5.3): AVAssetReader -> composition (trim, speed) -> CoreImage per frame (crop, rotate, scale, colour,
// watermark, burned-in text) -> AVAssetWriter with VideoToolbox (H.264, HEVC, ProRes) into MP4 or MOV. Stream copy goes straight reader -> writer.
// It writes 8-bit pictures; the planner says so when a 10-bit or HDR source loses depth.

enum VideoAVFExporter {
    /// plan -> `output` (the hidden `.part` path). Cancellation cancels reader and writer at once; nothing is left behind (the caller removes `output`).
    static func export(plan: VideoEncodePlan, input: URL, output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: input)
        guard (try? await asset.load(.isReadable)) == true else {
            throw ConversionError.unsupported(L10n("This format can only be read with ffmpeg (Settings > Tools).", "Этот формат можно прочитать только с ffmpeg (Настройки > Инструменты)."))
        }
        let job = try await Job(plan: plan, asset: asset, input: input, output: output, ctx: ctx, progress: progress)
        try await job.run()
    }

    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    struct Job {
        let plan: VideoEncodePlan
        let asset: AVURLAsset
        let output: URL
        let ctx: OperationContext
        let progress: ProgressSlice
        let range: CMTimeRange
        let videoTrack: AVAssetTrack?
        let audioTracks: [AVAssetTrack]
        let duration: Double
        let outSize: (w: Int, h: Int)
        let displaySize: (w: Int, h: Int)

        init(plan: VideoEncodePlan, asset: AVURLAsset, input: URL, output: URL, ctx: OperationContext, progress: ProgressSlice) async throws {
            self.plan = plan; self.asset = asset; self.output = output; self.ctx = ctx; self.progress = progress
            let total = (try? await asset.load(.duration)) ?? .zero
            let start = CMTime(seconds: plan.trimStart, preferredTimescale: 600)
            let end = plan.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? total
            guard end > start else { throw ConversionError.message(L10n("The end must come after the start.", "Конец должен быть позже начала.")) }
            range = CMTimeRange(start: start, end: min(end, total.isNumeric && total > .zero ? total : end))
            let v = try await asset.loadTracks(withMediaType: .video).first
            videoTrack = v
            let all = (try? await asset.load(.tracks)) ?? []
            var picked: [AVAssetTrack] = []
            let audios = try await asset.loadTracks(withMediaType: .audio)
            for (n, t) in plan.audioTracks.enumerated() {
                if all.indices.contains(t.sourceStream), all[t.sourceStream].mediaType == .audio { picked.append(all[t.sourceStream]) }
                else if audios.indices.contains(n) { picked.append(audios[n]) }
                else if let a = audios.first { picked.append(a) }
            }
            audioTracks = picked
            duration = max(0.001, range.duration.seconds / max(plan.picture.speed, 0.25))
            if let v {
                let nat = (try? await v.load(.naturalSize)) ?? .zero, tf = (try? await v.load(.preferredTransform)) ?? .identity
                let r = nat.applying(tf)
                displaySize = (Int(abs(r.width).rounded()), Int(abs(r.height).rounded()))
            } else { displaySize = (0, 0) }
            let s = plan.picture.outputSize ?? displaySize
            outSize = (VideoCI.even(s.w), VideoCI.even(s.h))
        }

        // MARK: Run

        func run() async throws {
            let isCopy = plan.videoCodec == "copy"
            let comp: AVMutableComposition? = isCopy ? nil : try await composition()
            let reader = try AVAssetReader(asset: comp ?? asset)
            let writer = try AVAssetWriter(outputURL: output, fileType: plan.container == "mov" ? .mov : .mp4)
            writer.shouldOptimizeForNetworkUse = plan.movFlagsFaststart
            writer.metadata = await metadataItems()
            let cancel = Cancel()
            var pumps: [Pump] = []

            // Video
            if let src = videoTrack, !plan.noVideo {
                if isCopy {
                    reader.timeRange = range
                    let out = AVAssetReaderTrackOutput(track: src, outputSettings: nil)
                    let hint = (try? await src.load(.formatDescriptions))?.first
                    let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
                    inp.transform = (try? await src.load(.preferredTransform)) ?? .identity
                    guard reader.canAdd(out), writer.canAdd(inp) else { throw ConversionError.noOutput }
                    reader.add(out); writer.add(inp)
                    pumps.append(Pump(output: out, input: inp, isVideo: true, offset: range.start.seconds))
                } else {
                    guard let comp else { throw ConversionError.noOutput }
                    let vc = try await videoComposition(for: comp)
                    let tracks = try await comp.loadTracks(withMediaType: .video)
                    let out = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    out.videoComposition = vc
                    let inp = AVAssetWriterInput(mediaType: .video, outputSettings: try videoSettings())
                    inp.expectsMediaDataInRealTime = false
                    guard reader.canAdd(out), writer.canAdd(inp) else { throw ConversionError.noOutput }
                    reader.add(out); writer.add(inp)
                    pumps.append(Pump(output: out, input: inp, isVideo: true, offset: 0))
                }
            }
            // Audio
            if !audioTracks.isEmpty, plan.audioCodec != "none" {
                if isCopy || plan.audioTracks.allSatisfy({ $0.codec == "copy" }) {
                    for t in audioTracks {
                        let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
                        let hint = (try? await t.load(.formatDescriptions))?.first
                        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                        if reader.canAdd(out), writer.canAdd(inp) { reader.add(out); writer.add(inp); pumps.append(Pump(output: out, input: inp, isVideo: false, offset: isCopy ? range.start.seconds : 0)) }
                    }
                } else {
                    let tracks = try await comp?.loadTracks(withMediaType: .audio) ?? []
                    if let first = plan.audioTracks.first, !tracks.isEmpty {
                        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings(first))
                        mix.audioTimePitchAlgorithm = .spectral
                        let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(first))
                        if reader.canAdd(mix), writer.canAdd(inp) { reader.add(mix); writer.add(inp); pumps.append(Pump(output: mix, input: inp, isVideo: false, offset: 0)) }
                    }
                }
            }
            guard !pumps.isEmpty else { throw ConversionError.noOutput }

            let handles = ReaderWriterPair(reader: reader, writer: writer)
            return try await withTaskCancellationHandler {
                guard writer.startWriting() else { throw writer.error ?? ConversionError.noOutput }
                guard reader.startReading() else { throw reader.error ?? ConversionError.noOutput }
                writer.startSession(atSourceTime: isCopy ? range.start : .zero)
                let started = Date()
                let total = duration
                await withTaskGroup(of: Void.self) { group in
                    for p in pumps {
                        group.addTask { await p.run(cancel: cancel, total: total, started: started, ctx: ctx, progress: progress) }
                    }
                }
                if cancel.isSet || Task.isCancelled {
                    reader.cancelReading(); writer.cancelWriting()
                    throw CancellationError()
                }
                if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? ConversionError.noOutput }
                await writer.finishWriting()
                if writer.status != .completed { throw writer.error ?? ConversionError.noOutput }
                progress.report(1)
            } onCancel: {
                cancel.set(); handles.reader.cancelReading(); handles.writer.cancelWriting()
            }
        }

        /// Pumps one reader output into one writer input on its own queue.
        struct Pump: @unchecked Sendable {
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            let isVideo: Bool
            let offset: Double

            func run(cancel: Cancel, total: Double, started: Date, ctx: OperationContext, progress: ProgressSlice) async {
                let queue = DispatchQueue(label: "app.swampconverter.avf-pump.\(isVideo ? "v" : "a")")
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    input.requestMediaDataWhenReady(on: queue) {
                        while input.isReadyForMoreMediaData {
                            if cancel.isSet { input.markAsFinished(); c.resume(); return }
                            guard let sample = output.copyNextSampleBuffer() else { input.markAsFinished(); c.resume(); return }
                            if isVideo {
                                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - offset
                                if t.isFinite { progress.report(min(0.99, max(0, t / total))) }
                            }
                            if !input.append(sample) { input.markAsFinished(); c.resume(); return }
                        }
                    }
                }
            }
        }

        // MARK: Composition

        func composition() async throws -> AVMutableComposition {
            let comp = AVMutableComposition()
            if let src = videoTrack, !plan.noVideo, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(range, of: src, at: .zero)
                t.preferredTransform = (try? await src.load(.preferredTransform)) ?? .identity
            }
            for src in audioTracks {
                if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { try? t.insertTimeRange(range, of: src, at: .zero) }
            }
            if abs(plan.picture.speed - 1) > 0.0005 {
                comp.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / max(plan.picture.speed, 0.25)))
            }
            return comp
        }

        func videoComposition(for comp: AVMutableComposition) async throws -> AVMutableVideoComposition {
            let p = plan.picture
            let size = outSize
            let overlays = OverlayStack(plan: plan, size: size)
            let mutable = try await AVMutableVideoComposition.videoComposition(with: comp, applyingCIFiltersWithHandler: { request in
                let img = VideoCI.process(request.sourceImage, picture: p, outputSize: size)
                request.finish(with: overlays.apply(to: img, at: request.compositionTime.seconds), context: VideoCI.context)
            })
            mutable.renderSize = CGSize(width: size.w, height: size.h)
            if let fps = p.fps, fps > 0 { mutable.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded())) }
            return mutable
        }

        // MARK: Settings

        func videoSettings() throws -> [String: Any] {
            var comp: [String: Any] = [:]
            let codec: AVVideoCodecType
            switch plan.videoCodec {
            case "hevc": codec = .hevc
            case "prores": codec = proresCodec()
            default: codec = .h264
            }
            switch plan.rate {
            case .quality(let q): if plan.videoCodec != "prores" { comp[AVVideoQualityKey] = max(0.05, min(1, q / 100)) }
            case .bitrate(let k): comp[AVVideoAverageBitRateKey] = k * 1000
            default: break
            }
            if plan.videoCodec == "h264" { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if plan.videoCodec == "hevc" { comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String }
            if let fps = plan.picture.fps ?? nil { comp[AVVideoExpectedSourceFrameRateKey] = fps }
            var s: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: outSize.w, AVVideoHeightKey: outSize.h]
            if !comp.isEmpty && plan.videoCodec != "prores" { s[AVVideoCompressionPropertiesKey] = comp }
            if plan.videoCodec != "prores" {
                s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            }
            return s
        }

        func proresCodec() -> AVVideoCodecType {
            // The native profiles: the plan's `profile` is not carried by VideoEncodePlan, HQ is the standard choice for masters.
            .proRes422HQ
        }

        func pcmSettings(_ t: VideoAudioTrackPlan) -> [String: Any] {
            var s: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                    AVLinearPCMIsBigEndianKey: false]
            if let r = t.sampleRate { s[AVSampleRateKey] = r }
            if let c = t.channels { s[AVNumberOfChannelsKey] = c }
            return s
        }

        func audioSettings(_ t: VideoAudioTrackPlan) -> [String: Any] {
            var s: [String: Any] = [:]
            switch t.codec {
            case "alac": s[AVFormatIDKey] = kAudioFormatAppleLossless
            case "pcm16", "pcm24":
                s = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: t.codec == "pcm24" ? 24 : 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            default:
                s[AVFormatIDKey] = kAudioFormatMPEG4AAC
                s[AVEncoderBitRateKey] = (t.bitrateKbps ?? 160) * 1000
            }
            s[AVSampleRateKey] = t.sampleRate ?? 48000
            s[AVNumberOfChannelsKey] = t.channels ?? 2
            return s
        }

        func metadataItems() async -> [AVMetadataItem] {
            let md = plan.metadata
            var items: [AVMetadataItem] = []
            if md.mode == "keep" {
                for item in (try? await asset.load(.metadata)) ?? [] {
                    if md.noGPS, item.identifier == .quickTimeMetadataLocationISO6709 || item.identifier == .commonIdentifierLocation || item.key as? String == "©xyz" { continue }
                    items.append(item)
                }
            }
            let names: [String: AVMetadataIdentifier] = ["title": .commonIdentifierTitle, "artist": .commonIdentifierArtist, "album": .commonIdentifierAlbumName,
                                                         "description": .commonIdentifierDescription, "copyright": .commonIdentifierCopyrights]
            for (k, v) in md.tags.sorted(by: { $0.key < $1.key }) {
                guard let id = names[k] else { continue }
                let it = AVMutableMetadataItem()
                it.identifier = id; it.value = v as NSString; it.dataType = kCMMetadataBaseDataType_UTF8 as String
                items.append(it)
            }
            return items
        }
    }

    /// Watermarks and burned-in cues for the CoreImage handler (thread-safe: AVFoundation calls the handler from several threads).
    final class OverlayStack: @unchecked Sendable {
        private let lock = NSLock()
        private var fixed: [CIImage] = []
        private var segments: [(start: Double, end: Double, text: String)] = []
        private var style = VideoBurnStyle()
        private var cache: [String: CIImage] = [:]
        private let size: (w: Int, h: Int)

        init(plan: VideoEncodePlan, size: (w: Int, h: Int)) {
            self.size = size
            for o in plan.overlays {
                switch o {
                case .watermarkImage(let file, let pct, let opacity, let pos, let margin):
                    if let tmp = try? VideoOverlayRenderer.watermarkPNG(from: file, tempDirectory: FileManager.default.temporaryDirectory, name: "wm-\(Util.hex8()).png"),
                       let src = CGImageSourceCreateWithURL(tmp as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        fixed.append(VideoCI.placed(cg, in: size, position: pos, margin: margin, opacity: opacity, width: max(16, Int(Double(size.w) * pct / 100))))
                    }
                case .watermarkText(let text, let pct, let opacity, let pos, let margin):
                    if let cg = VideoOverlayRenderer.renderWatermarkText(text, widthPixels: max(24, Int(Double(size.w) * pct / 100))) {
                        fixed.append(VideoCI.placed(cg, in: size, position: pos, margin: margin, opacity: opacity, width: nil))
                    }
                case .burnIn(let cues, let st):
                    segments = VideoOverlayRenderer.segments(cues, trimStart: plan.trimStart, speed: plan.picture.speed, outputDuration: plan.outputDuration)
                    style = st
                }
            }
        }

        func apply(to image: CIImage, at t: Double) -> CIImage {
            var out = image
            for w in fixed { out = w.composited(over: out) }
            if let seg = segments.first(where: { $0.start <= t && t < $0.end }) {
                lock.lock()
                var ci = cache[seg.text]
                if ci == nil, let cg = VideoOverlayRenderer.renderCue(seg.text, style: style, size: size) { ci = CIImage(cgImage: cg); cache[seg.text] = ci }
                lock.unlock()
                if let c = ci { out = c.composited(over: out) }
            }
            return out.cropped(to: CGRect(x: 0, y: 0, width: size.w, height: size.h))
        }
    }
}

/// The reader and writer, handed to the cancellation handler (which runs on another thread). `cancelReading` / `cancelWriting` are documented as callable from any thread.
private final class ReaderWriterPair: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
}
