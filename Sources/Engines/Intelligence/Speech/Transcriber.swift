import Foundation
import AVFoundation
import Speech
import CoreMedia

// B. On-device transcription. macOS 26 SpeechAnalyzer with SpeechTranscriber (or DictationTranscriber when the person installed that dictation language in
// System Settings). Everything stays on this Mac: the app never asks for a download and never uses a network recogniser. Speech is loaded on first use.

struct TranscriptWord: Equatable, Sendable {
    var text: String
    var start: Double
    var duration: Double
    var confidence: Double?
}

struct TranscriptSegment: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var words: [TranscriptWord] = []
}

enum SpeechAvailability: Equatable, Sendable {
    case available
    /// The language model is not on this Mac yet. Offline-only app: the hint says where the user can add it (System Settings), nothing is downloaded by us.
    /// `language` is a BCP-47 identifier ("ru-RU"); the message shows its name in both languages.
    case modelMissing(language: String)
    case languageUnsupported(language: String)
    case unavailable(reason: L10n)

    var reason: L10n? {
        switch self {
        case .available: return nil
        case .modelMissing(let id):
            let n = SpeechLanguageName.l10n(id)
            return L10n("The speech model for \(n.en) is not installed. Add the language in System Settings > Keyboard > Dictation.",
                        "Языковая модель для «\(n.ru)» не установлена. Добавьте язык в Системных настройках > Клавиатура > Диктовка.")
        case .languageUnsupported(let id):
            let n = SpeechLanguageName.l10n(id)
            return L10n("\(n.en) is not supported for on-device recognition on this Mac.", "Язык «\(n.ru)» не поддерживается для распознавания на устройстве.")
        case .unavailable(let r): return r
        }
    }
}

enum SpeechEngine {
    /// Test seam: replaces the recogniser (the operation tests feed fixed segments through the real writers). Never set in the app.
    nonisolated(unsafe) static var recogniserOverride: (@Sendable (URL, String?, OperationContext, ProgressSlice) async throws -> [TranscriptSegment])?

    /// Can this Mac transcribe `languageID` (BCP-47, e.g. "ru-RU") fully on device right now?
    static func availability(for languageID: String) async -> SpeechAvailability {
        await SpeechAvailabilityStore.shared.snapshot().availability(for: languageID)
    }

    /// Languages usable on device now (id + localised name) for the picker.
    static func supportedLanguages() async -> [(id: String, name: String)] {
        await SpeechAvailabilityStore.shared.snapshot().usable.map { e in
            let id = e.locale.identifier(.bcp47)
            return (id, SpeechLanguageName.text(id))
        }
    }

    /// Extracts the audio track (AVAssetReader; ffmpeg only for containers AVFoundation cannot open), transcribes it on device with timestamps,
    /// reports progress by audio time, honours cancellation within 200 ms, writes nothing next to the user's files. Never makes a network request:
    /// SpeechAnalyzer runs with locally installed models only (a missing model is a calm error, not a download).
    /// `languageID` nil or "auto" = the first language of the person's list that is installed.
    static func transcribe(input: URL, languageID: String?, ctx: OperationContext, progress: ProgressSlice) async throws -> [TranscriptSegment] {
        try await transcribeDetailed(input: input, languageID: languageID, ctx: ctx, progress: progress).segments
    }

    /// Same, and also says which language "auto" resolved to (BCP-47), for the language tag of a soft subtitle track.
    static func transcribeDetailed(input: URL, languageID: String?, ctx: OperationContext, progress: ProgressSlice) async throws -> (segments: [TranscriptSegment], language: String) {
        if let hook = recogniserOverride {
            let segments = try await hook(input, languageID, ctx, progress)
            return (segments, (languageID == nil || languageID == "auto") ? "en-US" : languageID!)
        }
        let snapshot = await SpeechAvailabilityStore.shared.snapshot()
        let entry = try resolve(languageID, in: snapshot)
        ctx.log("speech: \(entry.locale.identifier(.bcp47)) via \(entry.backend.rawValue)")
        let punctuation = ctx.options.bool(SpeechKeys.punctuation, true)

        let transcriberModule: any SpeechModule
        let collector: Task<[TranscriptSegment], Error>
        switch entry.backend {
        case .speechTranscriber:
            let t = SpeechTranscriber(locale: entry.locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            transcriberModule = t
            collector = Task { var out: [TranscriptSegment] = []; for try await r in t.results where r.isFinal { if let s = Self.segment(r.text, range: r.range) { out.append(s) } }; return out }
        case .dictation:
            var options: Set<DictationTranscriber.TranscriptionOption> = []
            if punctuation { options.insert(.punctuation) }
            let t = DictationTranscriber(locale: entry.locale, contentHints: [], transcriptionOptions: options, reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            transcriberModule = t
            collector = Task { var out: [TranscriptSegment] = []; for try await r in t.results where r.isFinal { if let s = Self.segment(r.text, range: r.range) { out.append(s) } }; return out }
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriberModule])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let source: SpeechAudioSource
        do { source = try await SpeechAudioSource.open(input, format: format, ctx: ctx) } catch { collector.cancel(); throw error }

        let priority: TaskPriority = ctx.isBackground ? .utility : .userInitiated
        let analyzer = SpeechAnalyzer(modules: [transcriberModule], options: SpeechAnalyzer.Options(priority: priority, modelRetention: .whileInUse))
        let sequence = SpeechAudioSequence(source: source) { fraction in progress.report(fraction * 0.98) }
        do {
            try await withTaskCancellationHandler {
                let last = try await analyzer.analyzeSequence(sequence)
                try Task.checkCancellation()
                if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
            } onCancel: {
                source.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
            let segments = try await collector.value
            progress.report(1)
            return (segments.sorted { $0.start < $1.start }, entry.locale.identifier(.bcp47))
        } catch {
            source.cancel()
            collector.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw map(error, languageID: entry.locale.identifier(.bcp47))
        }
    }

    /// "auto" / nil -> the first installed language of the person's list; a named language must be installed.
    static func resolve(_ languageID: String?, in snapshot: SpeechSnapshot) throws -> SpeechSnapshot.Entry {
        guard snapshot.frameworkAvailable else {
            throw ConversionError.message(SpeechAvailability.unavailable(reason: L10n("Speech recognition is not available on this Mac.", "Распознавание речи недоступно на этом Mac.")).reason!)
        }
        if languageID == nil || languageID == "auto" || languageID?.isEmpty == true {
            if let e = snapshot.autoEntry() { return e }
            throw ConversionError.message(L10n("No speech language is installed for on-device recognition. Add one in System Settings > Keyboard > Dictation.",
                                               "Для распознавания на устройстве не установлен ни один язык. Добавьте язык в Системных настройках > Клавиатура > Диктовка."))
        }
        let id = languageID!
        let state = snapshot.availability(for: id)
        guard state == .available, let e = snapshot.entry(for: id) else {
            throw ConversionError.message(state.reason ?? L10n("This language is not available.", "Этот язык недоступен."))
        }
        return e
    }

    private static func map(_ error: Error, languageID: String) -> Error {
        if error is ConversionError || error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == "SFSpeechErrorDomain" {
            // Code 3 ("Audio format is not supported") is what the framework reports when the model of the language cannot be loaded.
            if ns.code == 3 { return ConversionError.message(SpeechAvailability.modelMissing(language: languageID).reason!) }
        }
        return ConversionError.message(L10n("Speech recognition failed: \(ns.localizedDescription)", "Не удалось распознать речь: \(ns.localizedDescription)"))
    }

    // MARK: Results -> segments

    /// One recogniser result -> a segment with word timestamps from the `audioTimeRange` attribute of every run.
    static func segment(_ text: AttributedString, range: CMTimeRange) -> TranscriptSegment? {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
            if let tr = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self], tr.isValid {
                words.append(TranscriptWord(text: trimmed, start: tr.start.seconds, duration: max(tr.duration.seconds, 0), confidence: confidence))
            } else if var last = words.popLast(), !(piece.first?.isWhitespace ?? false) {
                last.text += trimmed   // punctuation run glued to the previous word
                words.append(last)
            } else {
                let at = words.last.map { $0.start + $0.duration } ?? (range.isValid ? range.start.seconds : 0)
                words.append(TranscriptWord(text: trimmed, start: at, duration: 0, confidence: confidence))
            }
        }
        let full = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return nil }
        let start = range.isValid ? range.start.seconds : (words.first?.start ?? 0)
        let end = range.isValid ? range.end.seconds : (words.last.map { $0.start + $0.duration } ?? start)
        return TranscriptSegment(start: start, end: max(end, start), text: full, words: words)
    }
}
