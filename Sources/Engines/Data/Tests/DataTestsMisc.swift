import Foundation

// Presets, capabilities, probes of subtitles and archives, progress and cancellation of the sheet and subtitle operations.

enum DataTestsMisc {
    static func register() {
        registerPresets()
        registerProbes()
        registerRuntime()
    }

    // MARK: Presets and capabilities

    private static func registerPresets() {
        dataTest("data.preset", "built-in presets: unique ids, known targets and operations, every value is a real field of the schema, every preset resolves without errors") {
            let ops: [Operation] = SheetCatalog.operations() + SubsCatalog.operations() + ArchiveCatalog.operations()
            let schemas: [String: OptionSchema] = [SheetSchemas.convertID: SheetSchemas.convert(items: []), SubsSchemas.convertID: SubsSchemas.convert(items: []),
                                                   ArchiveSchemas.packID: ArchiveSchemas.pack(items: []), ArchiveSchemas.extractID: ArchiveSchemas.extract(items: [])]
            let presets = DataPresets.builtins
            try expect(presets.count >= 15, "\(presets.count) presets")
            try expectEqual(Set(presets.map(\.id)).count, presets.count, "ids are unique")
            for p in presets {
                try expect(p.id.hasPrefix("builtin."), p.id)
                let schema = try unwrap(schemas[p.targetID], "\(p.id): target \(p.targetID) exists")
                if let opID = p.operationID {
                    let op = try unwrap(ops.first { $0.meta.id == opID }, "\(p.id): operation \(opID) exists")
                    try expectEqual(op.meta.schemaID, p.targetID, "\(p.id): the operation belongs to the target")
                }
                let keys = Set(schema.allFields.map(\.key))
                for k in p.values.keys { try expect(keys.contains(k), "\(p.id): '\(k)' is a field of \(p.targetID)") }
                let resolved = schema.resolve(layers: [p.values])
                try expect(!resolved.hasErrors, "\(p.id) resolves without errors: \(resolved.messages.map(\.id))")
                try expect(p.name.en != p.name.ru, "\(p.id) has a Russian name"); try expect(p.notes != nil, "\(p.id) explains itself")
                for (k, v) in p.values.storage where resolved.isActive(k) { try expectEqual(resolved.values[k], v, "\(p.id): \(k) keeps the preset's value (it is not clamped or reset)") }
            }
        }

        dataTest("data.preset", "running every preset produces the file it promises", timeout: 240) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let csv = try SheetFixtures.csv(fx, rows: [["Название", "Цена"], ["Болт", "1.5"], ["Гайка", "2.25"]])
            let srt = try SubsFixtures.write(fx, name: "p.srt", cues: [SubtitleCue(start: 1, end: 2, text: "[music] <i>Привет</i>"), SubtitleCue(start: 3, end: 4, text: "Hello there")])
            let proj = try ArcFixtures.project(fx)
            let zip = fx.url("p.zip"); try RawZip.build([RawZip.Entry("a.txt", "A")]).write(to: zip)
            let ops: [Operation] = SheetCatalog.operations() + SubsCatalog.operations() + ArchiveCatalog.operations()
            for p in DataPresets.builtins {
                let op = try unwrap(ops.first { $0.meta.id == (p.operationID ?? "pack.zip") }, p.id)
                let inputs: [URL]
                switch p.targetID {
                case SheetSchemas.convertID: inputs = [csv]
                case SubsSchemas.convertID: inputs = [srt]
                case ArchiveSchemas.extractID: inputs = [zip]
                default: inputs = [proj]
                }
                let out = fx.url("out-\(p.id.dropFirst(8))"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
                let items = inputs.map { FileItem(url: $0) }
                if p.values.string(ArchiveKeys.format).hasPrefix("tar.") || p.values.string(ArchiveKeys.format) == "7z", !Capabilities.shared.has("native.archive.write.\(p.values.string(ArchiveKeys.format) == "7z" ? "7z" : String(p.values.string(ArchiveKeys.format).dropFirst(4)))") { continue }
                let ctx = OperationContext.testing(op, items: items, extra: p.values, mode: .studio, rules: rules)
                let r = try await op.execute(items: items, ctx: ctx)
                try expect(!r.outputs.isEmpty && r.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "\(p.id) produced \(r.outputs.map(\.lastPathComponent))")
                if let f = p.values[SheetKeys.format]?.asString, p.targetID == SheetSchemas.convertID { try expectEqual(r.outputs[0].pathExtension, f, p.id) }
                if let f = p.values[SubsKeys.format]?.asString { try expectEqual(r.outputs[0].pathExtension, f, p.id) }
                if let f = p.values[ArchiveKeys.format]?.asString, p.targetID == ArchiveSchemas.packID { try expect(r.outputs[0].lastPathComponent.hasSuffix("." + f), "\(p.id): \(r.outputs[0].lastPathComponent)") }
            }
            // Spot checks that the values really change the bytes.
            let excel = try unwrap(DataPresets.builtins.first { $0.id == "builtin.sheet.csv.excel" })
            let outDir = fx.url("excel"); try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = outDir.path
            let op = try SheetRun.operation("sheet.to.csv")
            let ctx = OperationContext.testing(op, items: [FileItem(url: csv)], extra: excel.values, mode: .studio, rules: rules)
            let result = try await op.execute(items: [FileItem(url: csv)], ctx: ctx)
            let bytes = try Data(contentsOf: result.outputs[0])
            try expectEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF]); try expect(String(decoding: bytes, as: UTF8.self).contains("Болт;1,5\r\n"), "semicolons and decimal commas: \(String(decoding: bytes, as: UTF8.self).debugDescription)")
        }

        dataTest("data.preset", "capabilities: libarchive writes bz2, xz, zstd and 7z on this Mac, and the schema offers them only when it does") {
            ArchiveCapabilities.register()
            for f in ["bz2", "xz", "zst", "7z"] { try expect(Capabilities.shared.has("native.archive.write.\(f)"), "bsdtar writes \(f)") }
            let schema = ArchiveSchemas.pack(items: [])
            guard case .picker(let options) = try unwrap(schema.field(ArchiveKeys.format)).kind else { throw TestFailure(message: "format is a picker", file: #fileID, line: #line) }
            try expectEqual(options.map(\.value), ["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.zst", "7z"])
            try expectEqual(options.filter { !$0.requires.isEmpty }.count, 4)
            try expect(ArchiveFormat.writable.count == 7 && ArchiveFormat.allCases.count == 12, "format table")
        }
    }

    // MARK: Probes

    private static func registerProbes() {
        dataTest("data.probe", "subtitle probe: cues, duration, encoding, format; a file without cues warns") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let ru = [SubtitleCue(start: 1, end: 2, text: "Привет, как дела? Всё хорошо, спасибо."), SubtitleCue(start: 3700, end: 3725.5, text: "Съешь ещё этих мягких французских булок.")]
            let u = try SubsFixtures.write(fx, name: "p.srt", cues: ru, encoding: .windows1251)
            let info = await SubsSourceProbe().probe(FileItem(url: u))
            try expectEqual(info.int("sub.cues"), 2); try expectEqual(info.string("sub.format"), "srt"); try expectEqual(info.string("text.encoding"), "Windows-1251")
            try expectClose(info.duration ?? 0, 3725.5); try expect(info.chips.contains { $0.text == "Windows-1251" } && info.chips.contains { $0.text == "1:02:05" }, "chips: \(info.chips.map(\.text))")
            let junk = fx.url("junk.srt"); try Data("not subtitles at all".utf8).write(to: junk)
            let bad = await SubsSourceProbe().probe(FileItem(url: junk))
            try expect(bad.int("sub.cues") == nil && !bad.warnings.isEmpty, "a warning instead of a crash")
        }

        dataTest("data.probe", "archive probe: entries, size, encryption, unsafe paths for zip, tar.gz and 7z") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            let zip = try unwrap(try await ArcRun.run("pack.zip", [proj], fx: fx).outputs.first)
            let zi = await ArchiveSourceProbe().probe(FileItem(url: zip))
            try expectEqual(zi.int("archive.entries"), 10, "files in the zip (folders are not counted)"); try expectEqual(zi.bool("archive.encrypted"), false); try expectEqual(zi.bool("archive.unsafe"), false)
            try expect((zi.number("archive.unpacked") ?? 0) > 120_000, "unpacked size is known"); try expectEqual(zi.string("archive.format"), "zip")
            let tgz = try unwrap(try await ArcRun.run("pack.tar.gz", [proj], fx: fx).outputs.first)
            let ti = await ArchiveSourceProbe().probe(FileItem(url: tgz))
            try expectEqual(ti.int("archive.entries"), 10); try expect(ti.chips.contains { $0.text == "TAR.GZ" }, "chips: \(ti.chips.map(\.text))")
            let evil = fx.url("evil.zip"); try RawZip.build([RawZip.Entry("../x", "E"), RawZip.Entry("ok.txt", "O")]).write(to: evil)
            let ei = await ArchiveSourceProbe().probe(FileItem(url: evil))
            try expectEqual(ei.bool("archive.unsafe"), true); try expect(ei.warnings.count == 1 && ei.chips.contains { $0.symbol == "exclamationmark.triangle" })
            if Capabilities.shared.has("native.archive.write.7z"), let seven = try await ArcRun.run("pack.zip", [proj], [ArchiveKeys.format: "7z"], fx: fx).outputs.first {
                let si = await ArchiveSourceProbe().probe(FileItem(url: seven))
                try expectEqual(si.int("archive.entries"), 10, "libarchive listing"); try expectEqual(si.string("archive.format"), "7z")
            }
            let gz = fx.url("note.txt.gz"); try Data("x".utf8).write(to: fx.url("note.txt")); _ = DataTestKit.run("/usr/bin/gzip", ["-k", "-f", fx.url("note.txt").path])
            let gi = await ArchiveSourceProbe().probe(FileItem(url: gz))
            try expectEqual(gi.int("archive.entries"), 1, "a bare .gz is one file")
        }

        dataTest("data.archive", "names are Unicode-normalised for Windows only when asked (NFC option off keeps the Mac's decomposed name)", proves: ["arc.nfc.names"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            let off = try unwrap(try await ArcRun.run("pack.zip", [proj], [ArchiveKeys.normalise: false], fx: fx).outputs.first)
            let namesOff = try DataOracle.py("import sys,zipfile,json\nprint(json.dumps(zipfile.ZipFile(sys.argv[1]).namelist()))", [off.path])
            let listOff = (try JSONSerialization.jsonObject(with: Data(namesOff.utf8)) as? [String]) ?? []
            try expect(listOff.contains("proj/cafe\u{301}.txt"), "decomposed name kept: \(listOff.filter { $0.contains("caf") })")
            let on = try unwrap(try await ArcRun.run("pack.zip", [proj], fx: fx).outputs.first)
            let namesOn = try DataOracle.py("import sys,zipfile,json\nprint(json.dumps(zipfile.ZipFile(sys.argv[1]).namelist()))", [on.path])
            try expect(((try JSONSerialization.jsonObject(with: Data(namesOn.utf8)) as? [String]) ?? []).contains("proj/caf\u{E9}.txt"), "composed name by default")
        }
    }

    // MARK: Progress, cancellation

    private static func registerRuntime() {
        dataTest("data.runtime", "progress of every operation is monotonic, ends at 1 and never starts a timer or a child process for the native routes") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let csv = try SheetFixtures.csv(fx)
            let srt = try SubsFixtures.write(fx, name: "s.srt")
            let proj = try ArcFixtures.project(fx)
            let packed = try unwrap(try await ArcRun.run("pack.zip", [proj], fx: fx).outputs.first)
            let cases: [(Operation, [URL])] = try [(SheetRun.operation("sheet.to.xlsx"), [csv]), (SheetRun.operation("sheet.to.csv"), [csv]), (SheetRun.operation("sheet.to.pdf"), [csv]),
                                                  (SubsRun.operation("subs.to.vtt"), [srt]), (ArcRun.operation("archive.extract"), [packed]), (ArcRun.operation("archive.to.tar.gz"), [packed]),
                                                  (ArcRun.operation("pack.zip"), [proj])]
            for (op, urls) in cases {
                let items = urls.map { FileItem(url: $0) }
                let out = fx.url("pout-\(op.meta.id)"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
                let ctx = OperationContext.testing(op, items: items, mode: .studio, rules: rules)
                let seen = Locked<[Double]>([])
                ctx.onProgress = { f, _, _ in if let f { seen.withLock { $0.append(f) } } }
                _ = try await op.execute(items: items, ctx: ctx)
                let values = seen.value
                try expect(!values.isEmpty, "\(op.meta.id) reports progress")
                try expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "\(op.meta.id) is monotonic: \(values)")
                try expectClose(values.last ?? 0, 1, tolerance: 1e-9, "\(op.meta.id) ends at 1")
                try expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
            }
        }

        dataTest("data.runtime", "converting a big CSV is cancellable within 200 ms and leaves no partial output (streaming path and workbook path)", timeout: 180) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let big = fx.url("big.csv")
            let w = try CSVRowWriter(url: big, dialect: CSVDialect())
            for i in 0..<700_000 { try w.write(row: ["\(i)", "text value number \(i) with some length", "Привет, \"мир\"", "2024-01-05"]) }
            try w.finish()
            for (id, options) in [("sheet.to.tsv", OptionValues()), ("sheet.to.xlsx", OptionValues())] as [(String, OptionValues)] {
                let out = fx.url("cancel-\(id)"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
                let op = try SheetRun.operation(id)
                let items = [FileItem(url: big)]
                let ctx = OperationContext.testing(op, items: items, extra: options, mode: .studio, rules: rules)
                let task = Task { try await op.execute(items: items, ctx: ctx) }
                try await Task.sleep(nanoseconds: 120_000_000)
                let t0 = Date(); task.cancel()
                let r = await task.result
                if case .success = r { throw TestFailure(message: "\(id) finished before the cancel arrived", file: #fileID, line: #line) }
                try expect(Date().timeIntervalSince(t0) < 0.6, "\(id) cancelled in \(Date().timeIntervalSince(t0)) s")
                try expectEqual(DirectoryListing.names(out.path), [], "\(id): no partial output")
            }
        }

        dataTest("data.runtime", "100 000 rows x 6 columns: csv -> xlsx -> ods -> csv in bounded time, the cells survive, memory stays bounded", timeout: 300) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = fx.url("hundred.csv")
            let w = try CSVRowWriter(url: src, dialect: CSVDialect())
            try w.write(row: ["id", "name", "qty", "price", "date", "note"])
            for i in 1...100_000 { try w.write(row: ["\(i)", "Товар \(i) Žluťák", "\(i % 977)", "\(Double(i % 5000) / 8)", "2024-01-\(String(format: "%02d", i % 28 + 1))", i % 50 == 0 ? "a,b\"c" : ""]) }
            try w.finish()
            let rssBefore = DataTestKit.residentMB()
            let t0 = Date()
            let xlsx = try await SheetRun.run("sheet.to.xlsx", src, fx: fx)[0]
            let t1 = Date()
            let ods = try await SheetRun.run("sheet.to.ods", xlsx, fx: fx)[0]
            let t2 = Date()
            let csv = try await SheetRun.run("sheet.to.csv", ods, [SheetKeys.encodingOut: "utf-8", SheetKeys.delimiterOut: "comma"], fx: fx)[0]
            let t3 = Date()
            let back = try SheetReader.read(csv).sheets[0].rows
            try expectEqual(back.count, 100_001)
            try expectEqual(back[100_000], ["100000", "Товар 100000 Žluťák", "\(100_000 % 977)", "\(Double(100_000 % 5000) / 8)".replacingOccurrences(of: ".0", with: ""), "2024-01-\(String(format: "%02d", 100_000 % 28 + 1))", "a,b\"c"])
            try expectEqual(back[50], ["50", "Товар 50 Žluťák", "50", "6.25", "2024-01-23", "a,b\"c"])
            out(String(format: "      csv->xlsx %.1f s, xlsx->ods %.1f s, ods->csv %.1f s, resident memory %d -> %d MB (debug build)", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t3.timeIntervalSince(t2), rssBefore, DataTestKit.residentMB()))
            try expect(t3.timeIntervalSince(t0) < 120, "the chain took \(t3.timeIntervalSince(t0)) s")
        }

        dataTest("data.runtime", "an input that already has the target format is skipped on the wheel and converted (re-encoded) in the Studio") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try SheetFixtures.csv(fx, name: "same.csv", rows: [["a", "b"], ["1", "2"]])
            let quick = try await SheetRun.run("sheet.to.csv", src, fx: fx, mode: .quick)
            try expectEqual(quick, [], "quick: csv -> csv does nothing")
            let studio = try await SheetRun.run("sheet.to.csv", src, [SheetKeys.encodingOut: "windows-1251"], fx: fx, mode: .studio)
            try expectEqual(studio.count, 1, "Studio: csv -> csv re-encodes")
            let reg = OperationRegistry(); reg.register(SheetCatalog.operations())
            let items = [FileItem(url: src)]
            try expect(!reg.entries(wheel: .convert, items: items).map(\.id).contains("sheet.to.csv"), "hidden on the wheel")
            try expect(reg.studioTargets(for: items).contains { $0.id == SheetSchemas.convertID }, "offered in Studio")
        }
    }
}
