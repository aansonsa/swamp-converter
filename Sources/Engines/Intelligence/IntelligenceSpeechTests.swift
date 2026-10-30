import Foundation
import AVFoundation
import AppKit

// B. Transcription. Pure formatter goldens, the operation through the recogniser test seam (every option proven on the files it writes), availability experiments
// for ru-RU / en-US / lv-LV (SKIP with the reason when a model is missing, nothing is ever downloaded) and, where a model exists, a real transcription of speech
// made by the system voice.

enum IntelligenceSpeechTests {
    static func words(_ text: String, start: Double, step: Double) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { TranscriptWord(text: String($0.element), start: start + Double($0.offset) * step, duration: step * 0.9, confidence: 0.9) }
    }

    static let t1 = "Hello and welcome to the Swamp Converter demo, where every file gets a better home."
    static let t2 = "Short one."
    static let t3 = "Это длинная русская фраза для проверки переноса строк в субтитрах, которая не помещается в одну строку."
    static var segments: [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 6.5, text: t1, words: words(t1, start: 0, step: 0.4)),
         TranscriptSegment(start: 8, end: 8.6, text: t2, words: words(t2, start: 8, step: 0.3)),
         TranscriptSegment(start: 12, end: 18, text: t3, words: words(t3, start: 12, step: 0.35)),
         TranscriptSegment(start: 20, end: 22, text: "no word timing here at all", words: [])]
    }

    /// True when the data module's SubtitleKit is the real one (the skeleton stub returns an empty string).
    static var subtitleKitIsReal: Bool { !SubtitleKit.serialize([SubtitleCue(start: 0, end: 1, text: "a")], as: .srt).isEmpty }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("intelligence", "transcript.cues: golden splitting, 42 x 2 lines, 6 s, no words lost, no overlap") {
            let cues = TranscriptFormatter.cues(from: segments)
            try expectEqual(cues.count, 5)
            try expectEqual(cues[0].text, "Hello and welcome to the Swamp Converter\ndemo, where every file gets a better home.")
            try expectClose(cues[0].start, 0, tolerance: 0.001)
            try expectClose(cues[0].end, 5.96, tolerance: 0.001)
            try expectEqual(cues[1].text, "Short one.")
            try expectClose(cues[1].end, 8.57, tolerance: 0.001)
            try expectEqual(cues[2].text, "Это длинная русская фраза для проверки\nпереноса строк в субтитрах, которая не")
            try expectEqual(cues[3].text, "помещается в одну строку.")
            try expectEqual(cues[4].text, "no word timing here at all")
            try expectClose(cues[4].start, 20, tolerance: 0.001, "without word times the segment times are used")
            try expectClose(cues[4].end, 22, tolerance: 0.001)
            for c in cues {
                let lines = c.text.split(separator: "\n")
                try expect(lines.count <= 2 && lines.allSatisfy { $0.count <= 42 }, "line limit: \(c.text)")
                try expect(c.end - c.start <= 6.0001 && c.end > c.start, "duration \(c.start)-\(c.end)")
            }
            for (a, b) in zip(cues, cues.dropFirst()) { try expect(a.end <= b.start + 0.0001, "overlap \(a.end) > \(b.start)") }
            let said = segments.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
            let shown = cues.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
            try expectEqual(shown.map(String.init), said.map(String.init), "every word, in order")
        }

        t.register("intelligence", "transcript.cues: line length and duration limits are honoured") {
            let narrow = TranscriptFormatter.cues(from: segments, maxCharsPerLine: 20, maxDuration: 6)
            try expect(narrow.count > TranscriptFormatter.cues(from: segments).count, "narrower lines need more cues")
            for c in narrow { try expect(c.text.split(separator: "\n").count <= 2 && c.text.split(separator: "\n").allSatisfy { $0.count <= 20 }, "line limit 20: \(c.text)") }
            let quick = TranscriptFormatter.cues(from: segments, maxCharsPerLine: 42, maxDuration: 2)
            for c in quick { try expect(c.end - c.start <= 2.0001 || c.text.split(separator: " ").count == 1, "duration limit 2 s: \(c.start)-\(c.end) \(c.text)") }
            try expect(quick.count > 5)
            // CJK has no spaces: lines still stay inside the limit.
            let cjk = "これは長い日本語の文章でスペースがありません。それでも字幕は読みやすく分割されるべきです。"
            let seg = TranscriptSegment(start: 0, end: 8, text: cjk, words: cjk.map { TranscriptWord(text: String($0), start: 0, duration: 0.1) }.enumerated().map { var w = $0.element; w.start = Double($0.offset) * 0.2; return w })
            for c in TranscriptFormatter.cues(from: [seg], maxCharsPerLine: 20, maxDuration: 6) { try expect(c.text.split(separator: "\n").allSatisfy { $0.count <= 20 }, c.text) }
        }

        t.register("intelligence", "transcript.text: paragraphs by pause, time stamps, punctuation removal") {
            let plain = TranscriptFormatter.text(from: segments, timestamps: false, paragraphGap: 2)
            try expectEqual(plain, "\(t1) \(t2)\n\n\(t3) no word timing here at all\n")
            let stamped = TranscriptFormatter.text(from: segments, timestamps: true, paragraphGap: 2)
            try expectEqual(stamped, "[00:00:00] \(t1)\n[00:00:08] \(t2)\n\n[00:00:12] \(t3)\n[00:00:20] no word timing here at all\n")
            try expectEqual(TranscriptFormatter.text(from: segments, timestamps: false, paragraphGap: 0.5).components(separatedBy: "\n\n").count, 4, "a tiny gap splits at every pause")
            try expectEqual(TranscriptFormatter.stamp(3725.9), "01:02:05")
            try expectEqual(TranscriptFormatter.removingPunctuation("Hello, world! It's «fine» (really) — co-op."), "Hello world It's fine really co-op")
            let stripped = TranscriptFormatter.removingPunctuation(segments)
            try expect(!stripped[0].text.contains(",") && !stripped[0].text.contains("."))
            try expectEqual(stripped[0].words.count, segments[0].words.count)
            try expectEqual(TranscriptFormatter.text(from: [], timestamps: true), "")
        }

        t.register("intelligence", "transcript.srt/vtt: written by SubtitleKit, they read back to the same cues") {
            guard subtitleKitIsReal else { try skipTest("SubtitleKit.serialize is not available in this build yet (data module)") }
            let cues = TranscriptFormatter.cues(from: segments)
            let srt = TranscriptFormatter.srt(from: segments), vtt = TranscriptFormatter.vtt(from: segments)
            try expect(srt.contains(" --> ") && srt.hasPrefix("1\n"), "SRT shape: \(srt.prefix(80))")
            try expect(vtt.hasPrefix("WEBVTT"), "VTT header")
            for (name, text) in [("srt", srt), ("vtt", vtt)] {
                let parsed = try SubtitleKit.parse(text)
                try expectEqual(parsed.count, cues.count, "\(name) cue count")
                for (p, c) in zip(parsed, cues) {
                    try expectClose(p.start, c.start, tolerance: 0.001, "\(name) start")
                    try expectClose(p.end, c.end, tolerance: 0.001, "\(name) end")
                    try expectEqual(p.text.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines), c.text, "\(name) text")
                }
            }
        }

        t.register("intelligence", "speech.transcribe: every option changes the files it writes (recogniser test seam)") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let wav = try fx.wav("talk.wav", seconds: 1)
            let seen = Locked<[String?]>([])
            SpeechEngine.recogniserOverride = { _, language, _, progress in
                seen.withLock { $0.append(language) }
                progress.report(1)
                return segments
            }
            let pasted = Locked<[String]>([])
            let originalSink = TranscribeOperation.clipboardSink
            TranscribeOperation.clipboardSink = { text in pasted.withLock { $0.append(text) } }
            defer { SpeechEngine.recogniserOverride = nil; TranscribeOperation.clipboardSink = originalSink }

            // Default (quick): one TXT next to the source, named "(transcript)", also on the clipboard.
            let quick = try await IntelTest.run("speech.transcribe", [wav])
            try expectEqual(quick.outputs.map(\.lastPathComponent), ["talk (transcript).txt"])
            let txt = try String(contentsOf: quick.outputs[0], encoding: .utf8)
            try expectEqual(txt, TranscriptFormatter.text(from: segments, timestamps: false, paragraphGap: 2))
            try expectEqual(pasted.value, [txt], "the quick TXT is also on the clipboard")
            try expect(try unwrap(quick.note).en.contains("clipboard"))
            try expectEqual(seen.value.first ?? "x", "auto")

            // Studio mode never touches the clipboard.
            pasted.withLock { $0.removeAll() }
            _ = try await IntelTest.run("speech.transcribe", [wav], mode: .studio)
            try expect(pasted.value.isEmpty, "Studio must not write to the clipboard")

            // Language is passed to the recogniser.
            _ = try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.language: "ru-RU"], mode: .studio)
            try expectEqual(seen.value.last ?? "x", "ru-RU")

            // Time stamps, paragraph gap, punctuation.
            let stamped = try unwrap(try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.timestamps: true, SpeechKeys.paragraphGap: 0.5], mode: .studio).outputs.first)
            let s = try String(contentsOf: stamped, encoding: .utf8)
            try expect(s.contains("[00:00:08] Short one.") && s.contains("[00:00:12]"), s)
            try expectEqual(s.components(separatedBy: "\n\n").count, 4)
            let bare = try unwrap(try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.punctuation: false], mode: .studio).outputs.first)
            let b = try String(contentsOf: bare, encoding: .utf8)
            try expect(!b.contains(",") && !b.contains(".") && b.contains("Hello and welcome"), b)

            // Several formats in one go: one file each, the right extension, the right content.
            if subtitleKitIsReal {
                let multi = try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.format: "txt,srt,vtt"], mode: .studio)
                try expectEqual(multi.outputs.map(\.pathExtension), ["txt", "srt", "vtt"])
                try expect(multi.outputs.allSatisfy { $0.lastPathComponent.hasPrefix("talk (transcript)") })
                let srt = try String(contentsOf: multi.outputs[1], encoding: .utf8), vtt = try String(contentsOf: multi.outputs[2], encoding: .utf8)
                try expectEqual(srt, TranscriptFormatter.srt(from: segments))
                try expect(vtt.hasPrefix("WEBVTT"))
                // Cue options reach the subtitle files.
                let tight = try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.format: "srt", SpeechKeys.maxChars: 20, SpeechKeys.maxDuration: 2], mode: .studio)
                let parsed = try SubtitleKit.parse(try String(contentsOf: tight.outputs[0], encoding: .utf8))
                try expect(parsed.count > TranscriptFormatter.cues(from: segments).count)
                try expect(parsed.allSatisfy { $0.text.split(separator: "\n").allSatisfy { $0.count <= 20 } }, "characters per line")
                try expect(parsed.allSatisfy { $0.end - $0.start <= 2.0001 || $0.text.split(separator: " ").count == 1 }, "longest subtitle")
            } else {
                // Without the data module's writer the operation says so instead of leaving an empty .srt behind.
                let error = try await expectThrows { _ = try await IntelTest.run("speech.transcribe", [wav], extra: [SpeechKeys.format: "srt"], mode: .studio) }
                try expect(ConversionError.describe(error).contains("not available"), ConversionError.describe(error))
                try expect(!TestFile.exists(fx.url("talk (transcript).srt")), "no empty file may remain")
            }
            // A file with nothing recognised fails calmly instead of writing an empty transcript.
            SpeechEngine.recogniserOverride = { _, _, _, _ in [] }
            let error = try await expectThrows { _ = try await IntelTest.run("speech.transcribe", [wav]) }
            try expect(ConversionError.describe(error).lowercased().contains("no text"), ConversionError.describe(error))
        }

        t.register("intelligence", "speech.transcribe: schema fields carry oracles and the language list never needs a download") {
            let schema = SpeechSchemas.transcribe(items: [])
            for f in schema.allFields { try expect(!f.oracle.isEmpty, "field \(f.key) has no oracle") }
            try expect(schema.field(SpeechKeys.language) != nil && schema.field(SpeechKeys.burnIn) != nil)
            try expectEqual(SpeechKeys.formats("srt, txt"), ["txt", "srt"])
            try expectEqual(SpeechKeys.formats("nonsense"), ["txt"])
            let op = try IntelTest.operation("speech.transcribe")
            try expect(!op.meta.usesNetwork)
        }

        // MARK: Availability experiments (no download, ever)
        for (id, voice) in [("en-US", "Samantha"), ("ru-RU", "Milena"), ("lv-LV", "")] {
            t.register("intelligence", "speech.\(id): availability, and a real transcription when the model is installed", timeout: 180) {
                let state = await SpeechEngine.availability(for: id)
                out("      speech \(id): \(state)")
                guard state == .available else { try skipTest(state.reason?.en ?? "not available") }
                let say = URL(fileURLWithPath: "/usr/bin/say")
                guard !voice.isEmpty, FileManager.default.fileExists(atPath: say.path) else { try skipTest("no system voice for \(id) to make test speech") }
                let fx = TestFixtures(); defer { fx.cleanup() }
                let phrase = id == "ru-RU" ? "Привет. Это проверка распознавания речи на устройстве. Сегодня хорошая погода."
                    : "Hello. This is a test of speech recognition on this device. The weather is nice today."
                let aiff = fx.url("speech.aiff")
                _ = SyncProcess.run(say, ["-v", voice, "-o", aiff.path, phrase], timeout: 60)
                try expect(TestFile.exists(aiff), "say could not make the fixture")
                let op = try IntelTest.operation("speech.transcribe")
                let ctx = OperationContext.testing(op, items: [FileItem(url: aiff)], extra: [SpeechKeys.language: .string(id)])
                let fractions = Locked<[Double]>([])
                ctx.onProgress = { f, _, _ in if let f { fractions.withLock { $0.append(f) } } }
                let result = try await SpeechEngine.transcribeDetailed(input: aiff, languageID: id, ctx: ctx, progress: ctx.slice(index: 0, count: 1))
                let spoken = result.segments.flatMap(\.words)
                let heard = result.segments.map(\.text).joined(separator: " ").lowercased()
                out("      heard: \(heard)")
                let expected = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                let hits = expected.filter { heard.contains($0) }.count
                try expect(Double(hits) / Double(expected.count) >= 0.7, "recognised too little: \(heard)")
                try expect(!spoken.isEmpty && spoken.allSatisfy { $0.start >= 0 && $0.duration >= 0 }, "word timestamps")
                try expect(zip(spoken, spoken.dropFirst()).allSatisfy { $0.start <= $1.start + 0.001 }, "timestamps must not go backwards")
                let seconds = (try await AVURLAsset(url: aiff).load(.duration)).seconds
                try expect((spoken.last.map { $0.start + $0.duration } ?? 99) <= seconds + 0.6, "last word ends after the audio")
                try expect(fractions.value.count > 0 && zip(fractions.value, fractions.value.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 } && (fractions.value.last ?? 0) >= 0.99, "progress must rise to 1")
                try expectEqual(result.language.lowercased().prefix(2), id.lowercased().prefix(2))
            }
        }

        t.register("intelligence", "speech.transcribe: a video's sound track and an MKA container are read, cancellation is quick", requires: ["tool.ffmpeg"], timeout: 180) {
            let state = await SpeechEngine.availability(for: "en-US")
            guard state == .available else { try skipTest(state.reason?.en ?? "not available") }
            let fx = TestFixtures(); defer { fx.cleanup() }
            let phrase = "Hello. This is a test of speech recognition on this device. " + String(repeating: "The weather is nice today and the swamp is quiet. ", count: 40)
            let aiff = fx.url("speech.aiff")
            _ = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/say"), ["-v", "Samantha", "-o", aiff.path, phrase], timeout: 90)
            try expect(TestFile.exists(aiff))
            let clip = try await fx.video("clip.mp4", seconds: 1)
            let mp4 = fx.url("talk.mp4"), mka = fx.url("talk.mka")
            _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", clip.path, "-i", aiff.path, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", mp4.path])
            _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", aiff.path, "-c:a", "flac", mka.path])
            let op = try IntelTest.operation("speech.transcribe")
            for url in [mp4, mka] {
                let ctx = OperationContext.testing(op, items: [FileItem(url: url)])
                defer { ctx.cleanupTemp() }
                // Cancel as soon as recognition has started; the call must end quickly with a cancellation, not with a finished transcript.
                let started = IntelSignal()
                ctx.onProgress = { f, _, _ in if (f ?? 0) > 0.01 { started.fire() } }
                let task = Task { try await SpeechEngine.transcribeDetailed(input: url, languageID: "en-US", ctx: ctx, progress: ctx.slice(index: 0, count: 1)) }
                let didStart = await started.wait(timeout: 20)
                try expect(didStart, "recognition never started for \(url.lastPathComponent)")
                let t0 = Date()
                task.cancel()
                let outcome = await task.result
                let took = Date().timeIntervalSince(t0)
                guard case .failure(let error) = outcome else { throw TestFailure(message: "the run finished instead of stopping (\(url.pathExtension))", file: #fileID, line: #line) }
                try expect(error is CancellationError, "expected a cancellation, got \(error)")
                out("      \(url.pathExtension): cancelled in \(String(format: "%.0f", took * 1000)) ms")
                try expect(took < 0.5, "cancellation took \(took) s")
            }
            // A short complete run through the mp4 proves the video route.
            let ctx = OperationContext.testing(op, items: [FileItem(url: mp4)])
            defer { ctx.cleanupTemp() }
            let short = fx.url("short.mp4")
            let shortAiff = fx.url("short.aiff")
            _ = SyncProcess.run(URL(fileURLWithPath: "/usr/bin/say"), ["-v", "Samantha", "-o", shortAiff.path, "Hello. The swamp is quiet."], timeout: 60)
            _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", clip.path, "-i", shortAiff.path, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", short.path])
            let r = try await SpeechEngine.transcribeDetailed(input: short, languageID: "en-US", ctx: ctx, progress: ctx.slice(index: 0, count: 1))
            let heard = r.segments.map(\.text).joined(separator: " ").lowercased()
            try expect(heard.contains("swamp") || heard.contains("quiet"), "heard: \(heard)")
        }

        t.register("intelligence", "speech.transcribe: subtitles inside a copy of the video (burned in / soft track)", requires: ["tool.ffmpeg", "tool.ffprobe"], timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let clip = try await fx.video("clip.mp4", seconds: 3, size: CGSize(width: 320, height: 240), fps: 24)
            let cue = [TranscriptSegment(start: 1, end: 2, text: "Subtitle test line", words: words("Subtitle test line", start: 1, step: 0.3))]
            SpeechEngine.recogniserOverride = { _, _, _, _ in cue }
            defer { SpeechEngine.recogniserOverride = nil }

            if Capabilities.shared.has("ff.enc.libx264") || Capabilities.shared.has("ff.enc.h264_videotoolbox") {
                let burned = try unwrap(try await IntelTest.run("speech.transcribe", [clip], extra: [SpeechKeys.burnIn: true], mode: .studio).outputs.first { $0.pathExtension == "mp4" })
                try expectEqual(burned.lastPathComponent, "clip (subtitled).mp4")
                let codec = (IntelTest.tool(.ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", "-of", "csv=p=0", burned.path]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try expectEqual(codec, "h264,320,240")
                // Pixels: the bottom band changes while a cue is shown, the top does not; outside the cue nothing changes.
                func frame(_ url: URL, at t: Double, _ name: String) throws -> URL {
                    let png = fx.url(name)
                    _ = IntelTest.tool(.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(t), "-i", url.path, "-frames:v", "1", png.path])
                    try expect(TestFile.exists(png), "no frame at \(t)")
                    return png
                }
                func bandDifference(_ a: URL, _ b: URL, bottom: Bool) throws -> Double {
                    let size = try unwrap(TestImage.size(of: a))
                    var sum = 0.0, n = 0.0
                    let rows = bottom ? Array((size.height * 3 / 4)..<size.height) : Array(0..<(size.height / 2))
                    for y in stride(from: rows.first!, to: rows.last! + 1, by: 3) { for x in stride(from: 0, to: size.width, by: 3) {
                        let p = try unwrap(TestImage.pixel(of: a, x: x, y: y)), q = try unwrap(TestImage.pixel(of: b, x: x, y: y))
                        sum += Double(abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g)) + abs(Int(p.b) - Int(q.b))) / 3; n += 1
                    } }
                    return sum / n
                }
                let srcDuring = try frame(clip, at: 1.5, "src1.png"), outDuring = try frame(burned, at: 1.5, "out1.png")
                let srcOutside = try frame(clip, at: 0.4, "src0.png"), outOutside = try frame(burned, at: 0.4, "out0.png")
                let during = try bandDifference(srcDuring, outDuring, bottom: true), outside = try bandDifference(srcOutside, outOutside, bottom: true)
                let top = try bandDifference(srcDuring, outDuring, bottom: false)
                out("      burn-in band difference: during \(String(format: "%.1f", during)), outside \(String(format: "%.1f", outside)), top \(String(format: "%.1f", top))")
                try expect(during > outside * 2 + 3, "the subtitle must be visible during the cue (during \(during), outside \(outside))")
                try expect(top < during / 2, "the top of the picture must not change (top \(top), bottom \(during))")
                let dur = Double((IntelTest.tool(.ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", burned.path]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                try expectClose(dur, 3, tolerance: 0.25, "duration")
            }

            guard subtitleKitIsReal else { try skipTest("burn-in checked; the soft track part needs SubtitleKit.serialize (data module)") }
            let soft = try unwrap(try await IntelTest.run("speech.transcribe", [clip], extra: [SpeechKeys.mergeIntoVideo: true], mode: .studio).outputs.first { $0.lastPathComponent.contains("with subtitles") })
            let streams = IntelTest.tool(.ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "csv=p=0", soft.path]) ?? ""
            try expect(streams.contains("mov_text,subtitle"), "soft subtitle track missing: \(streams)")
            try expectEqual(IntelTest.streamHash(soft, stream: "0:v:0"), IntelTest.streamHash(clip, stream: "0:v:0"), "the picture must be copied, not re-encoded")
        }
    }
}
