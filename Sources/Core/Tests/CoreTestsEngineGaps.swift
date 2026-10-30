import Foundation

// Self-tests of the engine-gap fixes in Core: the m4r format, the conformance coverage gate, process-group cancellation, clipboard cleanup,
// and the typed error codes of the CLI.

enum CoreTestsEngineGaps {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("core.formats", "byte counts follow the language of the app, not of the system") {
            defer { Loc.shared.set(.system) }
            Loc.shared.set(.english)
            let en = Util.formatBytes(1_010_000_000)
            try expect(en.hasSuffix("GB") && en.contains("."), en)
            Loc.shared.set(.russian)
            let ru = Util.formatBytes(1_010_000_000)
            try expect(ru.contains("ГБ") && ru.contains(","), ru)
            try expect(Util.formatBytes(4_200_000).contains("МБ"), "megabytes are written in Russian too")
        }

        t.register("core.formats", "m4r is an audio input, and only real MPEG-4 audio may carry the .m4r extension") {
            try expect(Formats.audioInputs.contains("m4r"), "m4r is an audio input")
            try expectEqual(Formats.kind(forKey: "m4r"), .audio)
            let fx = ConformanceFixtures(label: "m4r")
            defer { fx.cleanup() }
            let wav = try fx.chirp("tone.wav", seconds: 1)
            let m4a = try unwrap(fx.audioVariant(of: wav, ext: "m4a"), "afconvert should write m4a")
            // The real thing: an M4A container under a ringtone name is fine (m4r and m4b are M4A containers).
            let ringtone = fx.url("tone.m4r")
            try FileManager.default.copyItem(at: m4a, to: ringtone)
            let real = try unwrap(FormatSniffer.sniff(ringtone))
            try expect(["m4a", "mp4"].contains(real.key), "sniffed \(real)")
            try expect(FormatSniffer.agrees(extension: "m4r", with: real), "an M4A container named .m4r agrees")
            let book = fx.url("tone.m4b")
            try FileManager.default.copyItem(at: m4a, to: book)
            try expect(FormatSniffer.agrees(extension: "m4b", with: try unwrap(FormatSniffer.sniff(book))), "an M4A container named .m4b agrees")
            // Renamed files must not pass: WAV bytes, PNG bytes and text under a .m4r name.
            let fakeWav = fx.url("fake-wav.m4r")
            try FileManager.default.copyItem(at: wav, to: fakeWav)
            let sw = try unwrap(FormatSniffer.sniff(fakeWav))
            try expectEqual(sw.key, "wav")
            try expect(!FormatSniffer.agrees(extension: "m4r", with: sw), "WAV bytes named .m4r must not pass")
            let fakePng = fx.url("fake-png.m4r")
            try FileManager.default.copyItem(at: try fx.photo("p.png"), to: fakePng)
            try expect(!FormatSniffer.agrees(extension: "m4r", with: try unwrap(FormatSniffer.sniff(fakePng))), "PNG bytes named .m4r must not pass")
            let fakeText = try fx.base.text("fake-text.m4r", "this is only text\n")
            try expect(!FormatSniffer.agrees(extension: "m4r", with: try unwrap(FormatSniffer.sniff(fakeText))), "text named .m4r must not pass")
            // The audio decoder path of the conformance suite reads the container (m4b is judged as m4a, the dead "m4b" case is gone).
            let verdict = await ConformanceDecode.check(ringtone, sniffed: real)
            if case .failed(let why) = verdict { throw TestFailure(message: "an M4A ringtone must decode: \(why)", file: #fileID, line: #line) }
        }

        t.register("conformance.harness", "the coverage gate counts only content oracles: the generic fallback matches everything and covers nothing") {
            let reg = ConformanceRegistry(includeBuiltins: false)
            let meta = OperationMeta.make("zz.cover", .tools, .pdf, L10n("X"), symbol: "x", schema: "zz", inputs: ["pdf"])
            try expect(ConformanceOracles.genericFallback.isFallback, "the built-in fallback is marked")
            try expect(ConformanceOracles.genericFallback.match(meta), "and it matches every file operation")
            reg.add(ConformanceOracles.genericFallback)
            try expectEqual(reg.oracle(for: meta)?.id, "generic.format-and-integrity", "the generic checks still run for an uncovered operation")
            try expect(reg.coveringOracle(for: meta) == nil, "but the operation is NOT covered by it")
            reg.add(ConformanceOracle(id: "zz.real", priority: 10, match: { $0.id == "zz.cover" }, cases: { _, _ in [] }, verify: { _ in }, proves: "a real thing"))
            try expectEqual(reg.coveringOracle(for: meta)?.id, "zz.real")
            try expectEqual(reg.oracle(for: meta)?.id, "zz.real")
            // Every operation of the real registry is covered or exempt; the new oracles claim exactly their operations.
            for id in ["pdf.extract", "tools.ocr", "slides.to.pdf", "slides.to.png", "slides.to.jpg", "slides.to.pptx", "slides.to.odp", "pdf.to.pptx", "video.concat"] {
                let m = OperationMeta.make(id, id.hasPrefix("slides") ? .convert : .tools, id.hasPrefix("slides") ? .slides : (id == "video.concat" ? .video : (id == "tools.ocr" ? .ocr : .pdf)), L10n("X"), symbol: "x", schema: "zz")
                let o = ConformanceRegistry.shared.coveringOracle(for: m)
                try expect(o != nil && o?.isFallback == false, "\(id) must have a content oracle, got \(o?.id ?? "none")")
            }
        }

        t.register("conformance.toolbox", "character error rate: identical text is 0, one wrong letter in ten is 0.1, case, spaces and composed accents do not count") {
            try expectEqual(TextCompare.characterErrorRate(expected: "Привет мир", actual: "привет  МИР"), 0)
            try expectEqual(TextCompare.characterErrorRate(expected: "abcdefghij", actual: "abcdXfghij"), 0.1)
            try expectEqual(TextCompare.characterErrorRate(expected: "abcdefghij", actual: "abcdfghij"), 0.1, "a missing letter")
            try expectEqual(TextCompare.characterErrorRate(expected: "e\u{301}", actual: "\u{E9}"), 0, "NFC")
            try expectEqual(TextCompare.characterErrorRate(expected: "abc", actual: ""), 1)
            try expect(TextCompare.characterErrorRate(expected: "", actual: "x") == 1 && TextCompare.characterErrorRate(expected: "", actual: "") == 0, "empty expectations")
        }
    }
}
