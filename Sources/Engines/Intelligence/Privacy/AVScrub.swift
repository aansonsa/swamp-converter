import Foundation
import AVFoundation

// The AVFoundation route for video and audio, used when ffmpeg is not installed (or on request in tests). Media samples are copied untouched
// (passthrough preset); the metadata is replaced. Limits are honest: AVFoundation cannot write every container (mp4 / mov / m4v / m4a / caf / wav / aiff only)
// and its "sharing" filter removes location, make / model, software and the creation date as one block, so a person who wanted to keep the dates still loses them.
// The report is built by inspecting the result, so it always says what really happened.

enum AVScrub {
    /// Every metadata item of the file, all formats together.
    static func allMetadata(of asset: AVAsset) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats { if let found = try? await asset.loadMetadata(for: f) { items += found } }
        }
        if items.isEmpty, let found = try? await asset.load(.metadata) { items = found }
        return items
    }

    /// The tag vocabulary of `MediaScrub.item(forTag:)` for one AVFoundation item.
    static func item(for m: AVMetadataItem) -> ScrubReport.Item? {
        var key = ""
        if let id = m.identifier?.rawValue { key = String(id.split(separator: "/", maxSplits: 1).last ?? Substring(id)) }
        if key.isEmpty, let k = m.key as? String { key = k }
        if key.isEmpty, let c = m.commonKey?.rawValue { key = c }
        return MediaScrub.item(forTag: commonName(key))
    }

    /// What a person can say about the file with only AVFoundation.
    static func inspect(_ url: URL) async -> ScrubReport {
        let found = Set(await allMetadata(of: AVURLAsset(url: url)).compactMap(item(for:)))
        return ScrubReport(removed: ScrubReport.Item.allCases.filter(found.contains))
    }

    /// AVFoundation / QuickTime key names -> the tag vocabulary of `MediaScrub.item(forTag:)`.
    private static func commonName(_ key: String) -> String {
        switch key.lowercased() {
        case "creationdate": return "creation_time"
        case "location": return "location"
        case "make": return "make"
        case "model": return "model"
        case "software": return "software"
        case "artist": return "artist"
        case "title": return "title"
        case "albumname": return "album"
        case "description": return "description"
        case "copyrights": return "copyright"
        default: return key
        }
    }

    static func fileType(forExtension ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        case "m4a": return .m4a
        case "caf": return .caf
        case "wav": return .wav
        case "aiff": return .aiff
        default: return nil
        }
    }

    /// Copies the compressed samples of every picture / sound / subtitle track into a new file (AVAssetReader -> AVAssetWriter, no decoding, no encoding) whose
    /// metadata list holds everything except the selected groups. AVAssetExportSession cannot do this: an empty list means "keep the original" there.
    static func scrub(input: FileItem, output: URL, selection: ScrubSelection, ctx: OperationContext, progress: ProgressSlice? = nil) async throws -> ScrubReport {
        guard let type = fileType(forExtension: output.pathExtension) else {
            throw ConversionError.message(L10n("Removing metadata from .\(output.pathExtension) files needs ffmpeg. \(Tool.ffmpeg.installHint.en)",
                                               "Для удаления метаданных из файлов .\(output.pathExtension) нужен ffmpeg. \(Tool.ffmpeg.installHint.ru)"))
        }
        let asset = AVURLAsset(url: input.url)
        let all = await allMetadata(of: asset)
        let before = Set(all.compactMap(item(for:)))
        let kept = selection.everything ? [] : all.filter { m in item(for: m).map { !selection.selects($0) } ?? true }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: type)
        writer.metadata = kept
        writer.shouldOptimizeForNetworkUse = true
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in try await asset.load(.tracks) {
            guard [AVMediaType.video, .audio, .subtitle, .text, .closedCaption].contains(track.mediaType) else { continue }
            let hints = try await track.load(.formatDescriptions)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            let writerInput = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hints.first)
            if track.mediaType == .video { writerInput.transform = try await track.load(.preferredTransform) }
            if let tag = try? await track.load(.extendedLanguageTag) { writerInput.extendedLanguageTag = tag }
            guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else { continue }
            reader.add(readerOutput); writer.add(writerInput)
            pairs.append((readerOutput, writerInput))
        }
        guard !pairs.isEmpty else { throw ConversionError.noOutput }
        guard reader.startReading() else { throw reader.error ?? ConversionError.fileUnreadable(input.url) }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.outputNotWritable(output) }
        writer.startSession(atSourceTime: .zero)

        let cancelled = Locked(false)
        try ctx.checkCancelled()
        await withTaskCancellationHandler {
            await Pump.run(pairs, cancelled: cancelled, duration: duration, progress: progress)
        } onCancel: {
            cancelled.value = true
        }
        if cancelled.value || Task.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            throw CancellationError()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.noOutput }
        progress?.report(0.95)
        let after = Set(await allMetadata(of: AVURLAsset(url: output)).compactMap(item(for:)))
        return MediaScrub.report(before: ScrubReport.Item.allCases.filter(before.contains), after: ScrubReport.Item.allCases.filter(after.contains), selection: selection, route: "avfoundation")
    }
}

/// Moves samples from the reader outputs to the writer inputs, each input on its own queue as the writer asks for more.
private enum Pump {
    static func run(_ pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)], cancelled: Locked<Bool>, duration: Double, progress: ProgressSlice?) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                group.enter()
                let finished = Locked(false)
                let queue = DispatchQueue(label: "swamp.scrub.pump.\(index)", qos: .utility)
                nonisolated(unsafe) let output = pair.0
                nonisolated(unsafe) let input = pair.1
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if finished.value { return }
                        var sample: CMSampleBuffer?
                        if !cancelled.value { sample = output.copyNextSampleBuffer() }
                        if let sample, input.append(sample) {
                            if index == 0, duration > 0 { progress?.report(Swift.min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 1) * 0.95) }
                            continue
                        }
                        // End of the track, cancellation or a failed append: close this input once.
                        let already = finished.withLock { (flag: inout Bool) -> Bool in let was = flag; flag = true; return was }
                        if !already { input.markAsFinished(); group.leave() }
                        return
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
    }
}
