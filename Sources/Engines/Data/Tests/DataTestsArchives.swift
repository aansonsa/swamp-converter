import Foundation

// Packing: pack.zip / pack.tar.gz and archive.to.* on a realistic folder (Mac junk, hidden files, Unicode names, links, empty folders, executables), listed and extracted
// again by independent tools (libarchive's bsdtar, unzip, gzip, python's zipfile).

@MainActor
enum ArcRun {
    static func operation(_ id: String) throws -> Operation { try unwrap(ArchiveCatalog.operations().first { $0.meta.id == id }, "operation \(id)") }

    /// Runs `id` on `urls` in Studio mode; results land in a fresh folder inside the fixture root. `log` collects the job log.
    @discardableResult
    static func run(_ id: String, _ urls: [URL], _ options: OptionValues = OptionValues(), fx: TestFixtures, out: URL? = nil, collision: OutputCollision = .number,
                    log: Locked<[String]>? = nil) async throws -> OperationResult {
        let dir = out ?? fx.url("out-\(Util.hex8())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = dir.path; rules.collision = collision
        let op = try operation(id)
        let items = urls.map { FileItem(url: $0) }
        let ctx = OperationContext.testing(op, items: items, extra: options, mode: .studio, rules: rules)
        if let log { ctx.onLog = { line in log.withLock { $0.append(line) } } }
        let result = try await op.execute(items: items, ctx: ctx)
        try expect(TestFile.partials(in: dir).isEmpty, "no .part leftovers: \(TestFile.partials(in: dir))")
        return result
    }
}

enum ArcFixtures {
    static let compressible = DataTestKit.compressibleText(bytes: 120_000)

    /// A folder like the ones people archive from an external drive.
    @discardableResult
    static func project(_ fx: TestFixtures, name: String = "proj") throws -> URL {
        let root = try fx.makeDirectory(name)
        func file(_ rel: String, _ data: Data, mode: Int? = nil) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path) }
        }
        try file("readme.txt", Data("Hello".utf8))
        try file("src/main.swift", compressible)
        try file("src/util/helper.swift", Data("let x = 1\n".utf8))
        try file("docs/Привет мир.txt", Data("Привет".utf8))
        try file("docs/Žluťák.txt", Data("ž".utf8))
        try file("bin/run.sh", Data("#!/bin/sh\necho hi\n".utf8), mode: 0o755)
        try file("img/photo.jpg", DataTestKit.noise(bytes: 20_000))
        try file(".hidden", Data("h".utf8))
        try file(".DS_Store", Data("junk".utf8))
        try file("._readme.txt", Data("junk".utf8))
        try file("__MACOSX/readme.txt", Data("junk".utf8))
        try file("cafe\u{301}.txt", Data("decomposed e acute".utf8))     // NFD, the way a Mac may store it
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("docs/link-to-readme").path, withDestinationPath: "../readme.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: root.appendingPathComponent("readme.txt").path)
        return root
    }

    /// Entry names that a default pack of `project` holds (NFC), without the root folder name.
    static let defaultNames: Set<String> = ["", "readme.txt", "src", "src/main.swift", "src/util", "src/util/helper.swift", "docs", "docs/Привет мир.txt", "docs/Žluťák.txt", "docs/link-to-readme",
                                           "bin", "bin/run.sh", "img", "img/photo.jpg", ".hidden", "café.txt", "empty"]
}

enum ArcOracle {
    /// Entry names as an independent reader lists them (directories without the trailing slash), NFC: python's zipfile / tarfile, libarchive for zst and 7z (libarchive treats
    /// AppleDouble `._` entries specially and may hide them, which would hide exactly what the junk tests look for).
    static func names(_ url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        var raw: [String]
        if DataOracle.hasPython, ["zip", "tar", "gz", "tgz", "bz2", "xz"].contains(ext) {
            let script = """
            import sys, json, zipfile, tarfile
            p = sys.argv[1]
            if zipfile.is_zipfile(p): print(json.dumps(zipfile.ZipFile(p).namelist()))
            else: print(json.dumps([m.name for m in tarfile.open(p)]))
            """
            raw = (try JSONSerialization.jsonObject(with: Data(try DataOracle.py(script, [url.path]).utf8)) as? [String]) ?? []
        } else {
            let r = DataTestKit.run("/usr/bin/bsdtar", ["-tf", url.path])
            try expectEqual(r.status, 0, "bsdtar lists \(url.lastPathComponent): \(r.output.prefix(300))")
            raw = r.output.split(separator: "\n").map(String.init)
        }
        return raw.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "./", with: "", options: .anchored).precomposedStringWithCanonicalMapping }
    }

    static let zipInfoScript = """
    import sys, zipfile, json
    z = zipfile.ZipFile(sys.argv[1])
    print(json.dumps([{'name': i.filename, 'flag': i.flag_bits, 'attr': i.external_attr >> 16, 'date': list(i.date_time), 'type': i.compress_type, 'size': i.file_size, 'csize': i.compress_size} for i in z.infolist()]))
    """

    struct ZipInfo { var name: String; var flag: Int; var mode: Int; var date: [Int]; var method: Int; var size: Int; var csize: Int }

    static func zipInfo(_ url: URL) throws -> [ZipInfo] {
        let text = try DataOracle.py(zipInfoScript, [url.path])
        let arr = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
        return arr.map { ZipInfo(name: $0["name"] as? String ?? "", flag: $0["flag"] as? Int ?? 0, mode: $0["attr"] as? Int ?? 0, date: $0["date"] as? [Int] ?? [], method: $0["type"] as? Int ?? -1,
                                 size: $0["size"] as? Int ?? 0, csize: $0["csize"] as? Int ?? 0) }
    }

    /// Extracts with bsdtar into a fresh folder next to `url` and returns it.
    static func extract(_ url: URL, fx: TestFixtures) throws -> URL {
        let out = fx.url("x-\(Util.hex8())")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = DataTestKit.run("/usr/bin/bsdtar", ["-xf", url.path, "-C", out.path])
        try expectEqual(r.status, 0, "bsdtar extracts \(url.lastPathComponent): \(r.output.prefix(300))")
        return out
    }
}

enum DataTestsArchives {
    static func register() {
        dataTest("data.archive", "pack.zip: a valid zip (unzip, bsdtar, python agree), junk left out, empty folders and links kept, UTF-8 names with the flag, modes, bytes identical after extraction",
                 proves: ["arc.format.sniff", "arc.exclude.listing", "arc.nfc.names", "arc.verify.log"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            let log = Locked<[String]>([])
            let result = try await ArcRun.run("pack.zip", [proj], fx: fx, log: log)
            let zip = try unwrap(result.outputs.first)
            try expectEqual(zip.lastPathComponent, "proj.zip")
            try expectEqual(DataOracle.mime(zip), "application/zip")
            try expectEqual(DataTestKit.run("/usr/bin/unzip", ["-tq", zip.path]).status, 0, "unzip -t")
            let names = Set(try ArcOracle.names(zip))
            let expected = Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 })
            try expectEqual(names, expected, "listing equals the input minus junk")
            let info = try ArcOracle.zipInfo(zip)
            try expect(info.allSatisfy { $0.flag & 0x800 != 0 || $0.name.utf8.allSatisfy { $0 < 0x80 } }, "non-ASCII names carry the UTF-8 flag")
            try expect(info.contains { $0.name == "proj/café.txt" }, "NFD name stored as NFC: \(info.map(\.name).filter { $0.contains("caf") })")
            try expect(info.contains { $0.name == "proj/empty/" }, "the empty folder is kept")
            let run = try unwrap(info.first { $0.name == "proj/bin/run.sh" }); try expectEqual(run.mode & 0o777, 0o755, "the executable bit")
            let photo = try unwrap(info.first { $0.name == "proj/img/photo.jpg" }); try expectEqual(photo.method, 0, "photos are stored, not deflated again")
            let text = try unwrap(info.first { $0.name == "proj/src/main.swift" }); try expectEqual(text.method, 8); try expect(text.csize < text.size / 10, "text deflates")
            let readme = try unwrap(info.first { $0.name == "proj/readme.txt" }); try expectEqual(readme.date[0], 2020, "modification date kept (2020-09-13)")
            // Extract with libarchive and compare every file.
            let x = try ArcOracle.extract(zip, fx: fx)
            for rel in ["readme.txt", "src/main.swift", "src/util/helper.swift", "docs/Привет мир.txt", "docs/Žluťák.txt", "bin/run.sh", "img/photo.jpg", ".hidden", "café.txt"] {
                try expectEqual(DataTestKit.read(x.appendingPathComponent("proj/" + rel)), DataTestKit.read(proj.appendingPathComponent(rel == "café.txt" ? "cafe\u{301}.txt" : rel)), rel)
            }
            try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: x.appendingPathComponent("proj/docs/link-to-readme").path), "../readme.txt")
            try expect(FileManager.default.fileExists(atPath: x.appendingPathComponent("proj/empty").path), "empty folder restored")
            try expect(!FileManager.default.fileExists(atPath: x.appendingPathComponent("proj/.DS_Store").path) && !FileManager.default.fileExists(atPath: x.appendingPathComponent("proj/__MACOSX").path), "no junk")
            try expect(log.value.contains { $0.hasPrefix("Checked the archive: \(names.count) entries") }, "the check ran and said so: \(log.value.suffix(3))")
        }

        dataTest("data.archive", "pack.tar.gz: gzip and bsdtar accept it, same listing, bytes and modes, no owner names, deterministic",
                 proves: ["arc.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            let tgz = try unwrap(try await ArcRun.run("pack.tar.gz", [proj], fx: fx).outputs.first)
            try expectEqual(tgz.lastPathComponent, "proj.tar.gz")
            try expectEqual(DataOracle.mime(tgz), "application/gzip")
            try expectEqual(DataTestKit.run("/usr/bin/gzip", ["-t", tgz.path]).status, 0)
            try expectEqual(Set(try ArcOracle.names(tgz)), Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 }))
            let x = try ArcOracle.extract(tgz, fx: fx)
            try expectEqual(DataTestKit.read(x.appendingPathComponent("proj/src/main.swift")), ArcFixtures.compressible)
            let mode = try FileManager.default.attributesOfItem(atPath: x.appendingPathComponent("proj/bin/run.sh").path)[.posixPermissions] as? NSNumber
            try expectEqual(mode?.intValue ?? 0, 0o755)
            let listing = DataTestKit.run("/usr/bin/bsdtar", ["-tvf", tgz.path]).output
            try expect(!listing.contains(NSUserName()), "no user name inside the archive")
            // Same input, same options -> identical bytes when dates are not kept.
            let a = try unwrap(try await ArcRun.run("pack.tar.gz", [proj], [ArchiveKeys.keepDates: false], fx: fx).outputs.first)
            let b = try unwrap(try await ArcRun.run("pack.tar.gz", [proj], [ArchiveKeys.keepDates: false], fx: fx).outputs.first)
            try expectEqual(try Data(contentsOf: a), try Data(contentsOf: b), "deterministic output")
        }

        dataTest("data.archive", "what goes in: Mac junk on, hidden files off, patterns, root folder modes, same-name inputs, dates", proves: ["arc.exclude.listing", "arc.hidden.listing", "arc.patterns.listing", "arc.root.listing", "arc.dates.mtime"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            func names(_ o: OptionValues, inputs: [URL]? = nil) async throws -> Set<String> {
                Set(try ArcOracle.names(try unwrap(try await ArcRun.run("pack.zip", inputs ?? [proj], o, fx: fx).outputs.first)))
            }
            let everything = try await names([ArchiveKeys.excludeHidden: false])
            for junk in ["proj/.DS_Store", "proj/._readme.txt", "proj/__MACOSX", "proj/__MACOSX/readme.txt"] { try expect(everything.contains(junk), "\(junk) is included when junk is allowed") }
            let noHidden = try await names([ArchiveKeys.includeHidden: false])
            try expect(!noHidden.contains("proj/.hidden") && noHidden.contains("proj/readme.txt"), "dot files left out")
            let patterns = try await names([ArchiveKeys.excludePatterns: "*.swift, docs, img/*.jpg"])
            try expect(!patterns.contains("proj/src/main.swift") && !patterns.contains("proj/docs/Привет мир.txt") && !patterns.contains("proj/docs") && !patterns.contains("proj/img/photo.jpg"), "patterns match names and relative paths: \(patterns.sorted())")
            try expect(patterns.contains("proj/readme.txt") && patterns.contains("proj/img"), "the rest stays")
            let added = try await names([ArchiveKeys.rootFolder: "add"])
            try expectEqual(added, Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 }), "a single dropped folder already is the top folder: nothing is doubled")
            let two = try await names([ArchiveKeys.rootFolder: "add"], inputs: [proj.appendingPathComponent("readme.txt"), proj.appendingPathComponent("bin")])
            let wrapper = L("Archive", "Архив")
            try expectEqual(two, [wrapper, "\(wrapper)/readme.txt", "\(wrapper)/bin", "\(wrapper)/bin/run.sh"], "several inputs get one folder named like the archive")
            let loose = try await names([:], inputs: [proj.appendingPathComponent("readme.txt"), proj.appendingPathComponent("bin")])
            try expectEqual(loose, ["readme.txt", "bin", "bin/run.sh"], "as dropped keeps names at the root")
            let stripped = try await names([ArchiveKeys.rootFolder: "strip"])
            try expect(stripped.contains("readme.txt") && stripped.contains("src/main.swift") && !stripped.contains("proj"), "contents at the root: \(stripped.sorted().prefix(5))")
            // Two inputs with the same file name keep both.
            let d1 = try fx.makeDirectory("one"), d2 = try fx.makeDirectory("two")
            try Data("1".utf8).write(to: d1.appendingPathComponent("a.txt")); try Data("2".utf8).write(to: d2.appendingPathComponent("a.txt"))
            let same = try await names([:], inputs: [d1.appendingPathComponent("a.txt"), d2.appendingPathComponent("a.txt")])
            try expectEqual(same, ["a.txt", "a (2).txt"])
            // Dates: kept by default, 1980-01-01 when off.
            let kept = try ArcOracle.zipInfo(try unwrap(try await ArcRun.run("pack.zip", [proj], fx: fx).outputs.first))
            try expectEqual(try unwrap(kept.first { $0.name == "proj/readme.txt" }).date, [2020, 9, 13, 14, 26, 40], "the file's own date")
            let fixed = try ArcOracle.zipInfo(try unwrap(try await ArcRun.run("pack.zip", [proj], [ArchiveKeys.keepDates: false], fx: fx).outputs.first))
            try expect(fixed.allSatisfy { Array($0.date.prefix(3)) == [1980, 1, 1] }, "every entry is dated 1980-01-01: \(fixed.map(\.date).prefix(2))")
        }

        dataTest("data.archive", "compression level is monotonic on compressible data for zip, tar.gz, tar.xz, tar.bz2, tar.zst and 7z; level 0 stores", proves: ["arc.level.size"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.makeDirectory("data")
            try DataTestKit.compressibleText(bytes: 600_000).write(to: src.appendingPathComponent("a.txt"))
            var rng = SplitMix(seed: 5)
            var words = ""
            for _ in 0..<40_000 { words += "w\(rng.next() % 4000) " }
            try Data(words.utf8).write(to: src.appendingPathComponent("b.txt"))
            func size(_ fmt: String, _ level: Int) async throws -> Int64 {
                TestFile.size(try unwrap(try await ArcRun.run("pack.zip", [src], [ArchiveKeys.format: .string(fmt), ArchiveKeys.level: .int(level)], fx: fx).outputs.first))
            }
            for fmt in ["zip", "tar.gz"] {
                let l0 = try await size(fmt, 0), l1 = try await size(fmt, 1), l9 = try await size(fmt, 9)
                try expect(l0 > l1 && l1 >= l9, "\(fmt): store \(l0) > fast \(l1) >= best \(l9)")
                try expect(l0 > 800_000, "\(fmt) level 0 really stores (\(l0))")
            }
            for fmt in ["tar.xz", "tar.bz2", "tar.zst", "7z"] {
                guard Capabilities.shared.has("native.archive.write.\(fmt == "7z" ? "7z" : String(fmt.dropFirst(4)))") else { continue }
                let fast = try await size(fmt, 1), best = try await size(fmt, 9)
                try expect(best <= fast, "\(fmt): level 9 (\(best)) is not bigger than level 1 (\(fast))")
                try expect(best < 600_000, "\(fmt) compresses (\(best))")
            }
        }

        dataTest("data.archive", "tar.bz2, tar.xz, tar.zst and 7z results are real archives (real type by content, libarchive lists and extracts them)", proves: ["arc.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx)
            for (fmt, cap, mime) in [("tar.bz2", "bz2", "application/x-bzip2"), ("tar.xz", "xz", "application/x-xz"), ("tar.zst", "zst", "application/zstd"), ("7z", "7z", "application/x-7z-compressed")] {
                guard Capabilities.shared.has("native.archive.write.\(cap)") else { continue }
                let out = try unwrap(try await ArcRun.run("pack.zip", [proj], [ArchiveKeys.format: .string(fmt)], fx: fx).outputs.first)
                try expectEqual(out.pathExtension, fmt == "7z" ? "7z" : fmt.components(separatedBy: ".").last!)
                try expectEqual(DataOracle.mime(out), mime, fmt)
                try expectEqual(Set(try ArcOracle.names(out)), Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 }), fmt)
                let x = try ArcOracle.extract(out, fx: fx)
                try expectEqual(DataTestKit.read(x.appendingPathComponent("proj/src/main.swift")), ArcFixtures.compressible, fmt)
            }
        }

        dataTest("data.archive", "packing is cancellable within 200 ms and leaves no partial archive", timeout: 120) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let big = fx.url("big.bin")
            try DataTestKit.noise(bytes: 4_000_000).write(to: big)
            let h = try FileHandle(forWritingTo: big); try h.seekToEnd()
            for _ in 0..<60 { try h.write(contentsOf: DataTestKit.noise(bytes: 4_000_000, seed: 9)) }
            try h.close()
            let out = fx.url("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
            let op = try ArcRun.operation("pack.zip")
            let items = [FileItem(url: big)]
            let ctx = OperationContext.testing(op, items: items, extra: [ArchiveKeys.verify: false], mode: .studio, rules: rules)
            let task = Task { try await op.execute(items: items, ctx: ctx) }
            try await Task.sleep(nanoseconds: 60_000_000)
            let t0 = Date()
            task.cancel()
            let r = await task.result
            let took = Date().timeIntervalSince(t0)
            if case .success = r { throw TestFailure(message: "the pack finished before the cancel arrived; the machine is too fast", file: #fileID, line: #line) }
            try expect(took < 0.5, "cancelled in \(took) s")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "no archive and no .part file left")
        }
    }
}
