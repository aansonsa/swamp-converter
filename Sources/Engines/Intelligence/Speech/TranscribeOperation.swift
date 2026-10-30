import Foundation
import AppKit

enum SpeechKeys {
    static let language = "speech.lang"          // BCP-47 or "auto" (system language first)
    static let format = "speech.format"          // txt, srt, vtt (several joined by commas: "txt,srt")
    static let timestamps = "speech.timestamps"  // TXT: [00:01:23] stamps
    static let punctuation = "speech.punct"
    static let maxChars = "speech.maxChars"
    static let burnIn = "speech.burn"            // burn the subtitles into a copy of the video (needs ffmpeg)
    static let mergeIntoVideo = "speech.soft"    // add as soft subtitle track (mov_text)
    /// Longest cue in seconds (SRT / VTT / video subtitles).
    static let maxDuration = "speech.maxDuration"
    /// A pause longer than this many seconds starts a new paragraph in the TXT.
    static let paragraphGap = "speech.paragraphGap"

    /// "txt,srt" -> ["txt", "srt"] in canonical order; unknown words are ignored; never empty (falls back to TXT).
    static func formats(_ raw: String) -> [String] {
        let wanted = Set(raw.lowercased().split(whereSeparator: { $0 == "," || $0 == "+" || $0 == " " }).map(String.init))
        let ordered = ["txt", "srt", "vtt"].filter(wanted.contains)
        return ordered.isEmpty ? ["txt"] : ordered
    }
}

enum SpeechSchemas {
    static let transcribeID = "speech.transcribe"

    private static let textFormats: [OptionValue] = ["txt", "txt,srt", "txt,vtt", "txt,srt,vtt"]

    /// Picker entries: "Automatic" plus every language the framework lists (installed or installable) plus the common candidates, each with a hint when its model is missing.
    private static func languageOptions() -> [FieldOption] {
        let snapshot = SpeechAvailabilityStore.shared.peek()
        var ids = Set(SpeechCapabilities.candidateLanguages)
        if let snapshot { ids.formUnion(snapshot.entries.values.map { $0.locale.identifier(.bcp47) }) }
        let sorted = ids.sorted { SpeechLanguageName.english($0) < SpeechLanguageName.english($1) }
        let auto = FieldOption("auto", L10n("Automatic (your language first)", "Автоматически (сначала ваш язык)"))
        return [auto] + sorted.map { id in
            var hint: L10n?
            if let state = snapshot?.availability(for: id), state != .available {
                switch state {
                case .modelMissing: hint = L10n("Model not installed", "Модель не установлена")
                case .languageUnsupported: hint = L10n("Not supported on this Mac", "Не поддерживается на этом Mac")
                default: break
                }
            }
            return FieldOption(id, SpeechLanguageName.l10n(id), hint: hint)
        }
    }

    /// Pages Language, Result (files, text, subtitles), Video (burn-in / soft track). Works for an empty items array.
    static func transcribe(items: [FileItem]) -> OptionSchema {
        let cueEnabled = OptionExpr.any([.ne(SpeechKeys.format, "txt"), .eq(SpeechKeys.burnIn, true), .eq(SpeechKeys.mergeIntoVideo, true)])
        return OptionSchema(id: transcribeID, title: L10n("Transcribe", "Расшифровка"), symbol: "text.bubble", pages: [
            .make("language", symbol: "globe", L10n("Language", "Язык"), [
                .make("lang", L10n("Spoken language", "Язык речи"), footer: L10n("Recognition runs on this Mac with the speech models that are installed. Nothing is sent anywhere.",
                                                                                   "Распознавание идёт на этом Mac с установленными речевыми моделями. Ничего никуда не отправляется."), [
                    .picker(SpeechKeys.language, L10n("Language", "Язык"), languageOptions(), def: "auto").basic()
                        .help(L10n("Automatic uses the first language of your list that has an installed model. Add more in System Settings > Keyboard > Dictation.",
                                   "Автоматически берётся первый язык вашего списка с установленной моделью. Другие можно добавить в Системных настройках > Клавиатура > Диктовка."))
                        .affects([.plan]).aliases(["language", "язык", "locale"]).oracle("speech.lang.passed")
                ])
            ]),
            .make("result", symbol: "doc.text", L10n("Result", "Результат"), [
                .make("files", L10n("Files", "Файлы"), [
                    .picker(SpeechKeys.format, L10n("Create", "Создать"), [
                        FieldOption("txt", L10n("Text (TXT)", "Текст (TXT)")),
                        FieldOption("srt", L10n("Subtitles (SRT)", "Субтитры (SRT)")),
                        FieldOption("vtt", L10n("Subtitles (VTT)", "Субтитры (VTT)")),
                        FieldOption("txt,srt", L10n("Text and SRT", "Текст и SRT")),
                        FieldOption("txt,vtt", L10n("Text and VTT", "Текст и VTT")),
                        FieldOption("srt,vtt", L10n("SRT and VTT", "SRT и VTT")),
                        FieldOption("txt,srt,vtt", L10n("Text, SRT and VTT", "Текст, SRT и VTT"))
                    ], def: "txt").basic().affects([.plan]).aliases(["srt", "vtt", "txt", "субтитры"]).oracle("speech.format.files"),
                    .toggle(SpeechKeys.punctuation, L10n("Punctuation", "Знаки препинания"), def: true).basic()
                        .help(L10n("Off removes full stops, commas, question marks and quotes from the text.", "Выключено: из текста убираются точки, запятые, вопросительные знаки и кавычки."))
                        .affects([.plan]).oracle("speech.punct.text")
                ]),
                .make("text", L10n("Text file", "Текстовый файл"), [
                    .toggle(SpeechKeys.timestamps, L10n("Time stamps", "Метки времени")).enabled(.in(SpeechKeys.format, textFormats))
                        .help(L10n("Puts [00:01:23] in front of every phrase.", "Ставит [00:01:23] перед каждой фразой.")).affects([.plan]).oracle("speech.timestamps.txt"),
                    .slider(SpeechKeys.paragraphGap, L10n("New paragraph after a pause of", "Новый абзац после паузы"), min: 0.5, max: 6, step: 0.5, def: 2, unit: "s", decimals: 1)
                        .enabled(.in(SpeechKeys.format, textFormats)).standard().affects([.plan]).oracle("speech.paragraphGap.txt")
                ]),
                .make("subs", L10n("Subtitles", "Субтитры"), level: .standard, footer: L10n("Applies to SRT, VTT and to subtitles added to a video.", "Действует для SRT, VTT и субтитров в видео."), [
                    .slider(SpeechKeys.maxChars, L10n("Characters per line", "Символов в строке"), min: 20, max: 80, step: 1, def: 42)
                        .enabled(cueEnabled).standard().affects([.plan]).oracle("speech.maxChars.cues"),
                    .slider(SpeechKeys.maxDuration, L10n("Longest subtitle", "Самый длинный субтитр"), min: 2, max: 12, step: 0.5, def: 6, unit: "s", decimals: 1)
                        .enabled(cueEnabled).standard().affects([.plan]).oracle("speech.maxDuration.cues")
                ])
            ]),
            .make("video", symbol: "film", L10n("Video", "Видео"), [
                .make("embed", L10n("Subtitles in a copy of the video", "Субтитры в копии видео"), footer: L10n("Audio files and the original video are never changed.", "Аудиофайлы и исходное видео не изменяются."), [
                    .toggle(SpeechKeys.burnIn, L10n("Burn the subtitles into the picture", "Вжечь субтитры в изображение"))
                        .needs(["tool.ffmpeg"]).help(L10n("Makes a new video where the words are part of the picture. The video is encoded again.", "Создаёт новое видео, где слова — часть изображения. Видео кодируется заново."))
                        .affects([.plan]).oracle("speech.burn.pixels"),
                    .toggle(SpeechKeys.mergeIntoVideo, L10n("Add as a subtitle track", "Добавить дорожкой субтитров"))
                        .needs(["tool.ffmpeg"]).enabled(.eq(SpeechKeys.burnIn, false))
                        .help(L10n("Keeps the picture exactly as it is and adds a subtitle track that players can switch on and off.", "Картинка остаётся как есть, добавляется дорожка субтитров, которую плеер может включать и выключать."))
                        .affects([.plan]).oracle("speech.soft.track")
                ])
            ])
        ])
    }
}

/// `speech.transcribe`: audio/video -> `{name} (transcript).txt|srt|vtt`. Behaviour = f(items, ctx.options).
final class TranscribeOperation: PerFileOperation, @unchecked Sendable {
    /// Jobs whose TXT was also put on the clipboard (so `execute` can say so in the result note).
    private let clipboardJobs = Locked<Set<UUID>>([])

    /// Where the text of a single quick transcription goes. Tests replace it so they never touch the person's clipboard.
    nonisolated(unsafe) static var clipboardSink: @Sendable (String) async -> Void = { text in
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    override func optionSchema(for items: [FileItem]) -> OptionSchema { SpeechSchemas.transcribe(items: items) }
    override func quickOverrides(settings: SettingsData) -> OptionValues { [SpeechKeys.format: "txt", SpeechKeys.language: "auto"] }

    /// Disabled with the calm reason when the framework or every language model is missing. Reads the cached listing (never blocks the wheel);
    /// the first call after launch starts the listing in the background and answers "available".
    override func availability(for items: [FileItem], tools: ToolLocator) -> OperationAvailability {
        guard let snapshot = SpeechAvailabilityStore.shared.peek() else { return .available }
        if !snapshot.frameworkAvailable {
            return .unavailable(reason: L10n("Speech recognition is not available on this Mac.", "Распознавание речи недоступно на этом Mac."), missing: [])
        }
        if snapshot.autoEntry() == nil {
            return .unavailable(reason: L10n("No speech language is installed. Add one in System Settings > Keyboard > Dictation.",
                                             "Не установлен ни один язык распознавания. Добавьте язык в Системных настройках > Клавиатура > Диктовка."), missing: [])
        }
        return .available
    }

    override func validate(options: OptionValues, source: SourceInfo?) -> [OptionMessage] {
        guard let snapshot = SpeechAvailabilityStore.shared.peek() else { return [] }
        let id = options.string(SpeechKeys.language, "auto")
        if id == "auto" { return [] }
        let state = snapshot.availability(for: id)
        guard state != .available, let reason = state.reason else { return [] }
        return [OptionMessage(id: "speech.lang.unavailable", severity: .error, text: reason, fieldKey: SpeechKeys.language)]
    }

    override func summaryChips(options: OptionValues, source: SourceInfo?) -> [String] {
        var chips = SpeechKeys.formats(options.string(SpeechKeys.format, "txt")).map { $0.uppercased() }
        if options.bool(SpeechKeys.burnIn) { chips.append(L("Burned in", "Вжечь")) } else if options.bool(SpeechKeys.mergeIntoVideo) { chips.append(L("Subtitle track", "Дорожка")) }
        return chips
    }

    override func stagePlan(options: OptionValues) -> [StageSpec] { [.transcribe(), .finalize(weight: 0.3)] }

    // MARK: Running

    /// Phase 1 recognises every file (stage "transcribe"), phase 2 writes the files and the video copies (stage "finalize"). A failing file does not stop the others.
    override func execute(items: [FileItem], ctx: OperationContext) async throws -> OperationResult {
        var recognised: [(item: FileItem, segments: [TranscriptSegment], language: String)] = []
        var failures: [String] = []
        let count = items.count
        ctx.beginStage("transcribe")
        for (i, item) in items.enumerated() {
            try ctx.checkCancelled()
            try await ctx.waitIfPaused()
            ctx.setCurrentItem(item, index: i, count: count)
            do {
                let r = try await SpeechEngine.transcribeDetailed(input: item.url, languageID: ctx.options.string(SpeechKeys.language, "auto"), ctx: ctx, progress: ctx.slice(index: i, count: count))
                guard !r.segments.isEmpty else { throw ConversionError.noText }
                recognised.append((item, r.segments, r.language))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if count == 1 { throw error }
                failures.append("\(item.name): \(ConversionError.describe(error))")
                ctx.log("FAILED \(item.name): \(ConversionError.describe(error))")
            }
        }
        ctx.finishStage("transcribe")
        ctx.beginStage("finalize")
        var result = OperationResult()
        for (i, r) in recognised.enumerated() {
            try ctx.checkCancelled()
            ctx.setCurrentItem(r.item, index: i, count: recognised.count)
            do {
                result.outputs += try await write(r.item, segments: r.segments, language: r.language, ctx: ctx, progress: ctx.slice(index: i, count: recognised.count), singleFile: count == 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if count == 1 { throw error }
                failures.append("\(r.item.name): \(ConversionError.describe(error))")
            }
        }
        ctx.report(1)
        if result.outputs.isEmpty && !failures.isEmpty { throw ConversionError.aggregate(failures) }
        result.failures = failures
        if clipboardJobs.withLock({ $0.remove(ctx.jobID) != nil }) {
            result.note = L10n("The text is also on the clipboard.", "Текст также скопирован в буфер обмена.")
        }
        return result
    }

    override func process(_ item: FileItem, ctx: OperationContext, progress: ProgressSlice) async throws -> [URL] {
        let r = try await SpeechEngine.transcribeDetailed(input: item.url, languageID: ctx.options.string(SpeechKeys.language, "auto"), ctx: ctx, progress: progress)
        guard !r.segments.isEmpty else { throw ConversionError.noText }
        return try await write(item, segments: r.segments, language: r.language, ctx: ctx, progress: progress, singleFile: progress.count == 1)
    }

    /// Turns segments into the requested files. Exposed to the tests through `SpeechEngine.recogniserOverride`.
    private func write(_ item: FileItem, segments raw: [TranscriptSegment], language: String, ctx: OperationContext, progress: ProgressSlice, singleFile: Bool) async throws -> [URL] {
        let o = ctx.options
        let formats = SpeechKeys.formats(o.string(SpeechKeys.format, "txt"))
        let segments = o.bool(SpeechKeys.punctuation, true) ? raw : TranscriptFormatter.removingPunctuation(raw)
        let maxChars = o.int(SpeechKeys.maxChars, 42), maxDuration = o.double(SpeechKeys.maxDuration, 6)
        var outputs: [URL] = []
        for f in formats {
            let text: String
            switch f {
            case "srt": text = TranscriptFormatter.srt(from: segments, maxCharsPerLine: maxChars, maxDuration: maxDuration)
            case "vtt": text = TranscriptFormatter.vtt(from: segments, maxCharsPerLine: maxChars, maxDuration: maxDuration)
            default:
                text = TranscriptFormatter.text(from: segments, timestamps: o.bool(SpeechKeys.timestamps), paragraphGap: o.double(SpeechKeys.paragraphGap, 2))
            }
            guard !text.isEmpty else {
                throw ConversionError.message(L10n("Writing .\(f) files is not available in this build.", "Запись файлов .\(f) недоступна в этой сборке."))
            }
            outputs.append(try await ctx.produceFile(for: item, suffix: meta.suffix, ext: f) { url in try Data(text.utf8).write(to: url) })
            if f == "txt", ctx.mode == .quick, singleFile {
                await Self.clipboardSink(text)
                clipboardJobs.withLock { _ = $0.insert(ctx.jobID) }
            }
        }
        // Subtitles inside a copy of the video.
        let wantsBurn = o.bool(SpeechKeys.burnIn) && ctx.isActive(SpeechKeys.burnIn)
        let wantsSoft = !wantsBurn && o.bool(SpeechKeys.mergeIntoVideo) && ctx.isActive(SpeechKeys.mergeIntoVideo)
        guard wantsBurn || wantsSoft else { return outputs }
        guard item.kind == .video else { ctx.log("subtitles inside the file skipped: \(item.name) is not a video"); return outputs }
        let suffix = wantsBurn ? L10n("subtitled", "с субтитрами") : L10n("with subtitles", "с дорожкой субтитров")
        let ext = wantsBurn ? SubtitleVideo.outputExtension(for: item) : (SubtitleVideo.videoExtensions.contains(item.key) || item.key == "webm" ? item.key : "mkv")
        let cues = TranscriptFormatter.cues(from: segments, maxCharsPerLine: maxChars, maxDuration: maxDuration)
        outputs.append(try await ctx.produceFile(for: item, suffix: suffix, ext: ext) { url in
            if wantsBurn { try await SubtitleVideo.burn(item: item, cues: cues, output: url, ctx: ctx, progress: progress) }
            else { try await SubtitleVideo.addSoftTrack(item: item, cues: cues.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }, language: language, output: url, ctx: ctx, progress: progress) }
        })
        return outputs
    }
}
