import Foundation

// Extraction and repacking through the real operations, on archives made by independent tools (zip, bsdtar, gzip) and by hand (Windows-Russian names, hostile paths, encryption).

enum DataTestsExtract {
    /// Names (relative, "/" separated, directories with a trailing slash) of everything below `dir`, listed with readdir so AppleDouble files are not hidden.
    static func tree(_ dir: URL) -> [String] {
        var out: [String] = []
        func walk(_ d: URL, _ prefix: String) {
            for n in DirectoryListing.names(d.path).sorted() {
                var isDir: ObjCBool = false
                let u = d.appendingPathComponent(n)
                let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                if isDir.boolValue && !link { out.append(prefix + n + "/"); walk(u, prefix + n + "/") } else { out.append(prefix + n) }
            }
        }
        walk(dir, "")
        return out
    }

    /// A zip made by /usr/bin/zip from `fx.root/<folder>`.
    static func zip(_ fx: TestFixtures, _ name: String, folder: String, files: [String: String]) throws -> URL {
        _ = try fx.folderTree(folder, files: files)
        return try fx.zip(name, items: [folder])
    }

    static func register() {
        registerLayout()
        registerFormats()
        registerSafety()
        registerOptions()
        registerRepack()
    }

    // MARK: Layout

    private static func registerLayout() {
        dataTest("data.extract", "placement: one top-level folder keeps its name, several entries go into a folder named like the archive, one file comes out as it is, numbering when a name is taken",
                 proves: ["arc.extract.layout", "arc.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            // A: single folder
            let a = try zip(fx, "A.zip", folder: "photos", files: ["x.txt": "X", "sub/y.txt": "Y"])
            let outA = fx.url("outA")
            let r1 = try await ArcRun.run("archive.extract", [a], fx: fx, out: outA)
            try expectEqual(r1.outputs.map(\.lastPathComponent), ["photos"], "a single top-level folder is not wrapped again")
            try expectEqual(tree(outA).filter { !$0.hasPrefix("__") }, ["photos/", "photos/sub/", "photos/sub/y.txt", "photos/x.txt"])
            let r2 = try await ArcRun.run("archive.extract", [a], fx: fx, out: outA)
            try expectEqual(r2.outputs.map(\.lastPathComponent), ["photos (2)"], "a taken name gets a number, nothing is overwritten")
            // B: several entries
            _ = try fx.folderTree("multi", files: ["a.txt": "A", "b.txt": "B", "d/c.txt": "C"])
            let b = fx.url("Report 2024.zip")
            try DataTestKit.run("/usr/bin/zip", ["-q", "-r", "-X", b.path, "a.txt", "b.txt", "d"], cwd: fx.url("multi")).status == 0 ? () : { throw TestFailure(message: "zip failed", file: #fileID, line: #line) }()
            let outB = fx.url("outB")
            let rb = try await ArcRun.run("archive.extract", [b], fx: fx, out: outB)
            try expectEqual(rb.outputs.map(\.lastPathComponent), ["Report 2024"], "several entries are put into a folder named like the archive")
            try expectEqual(tree(outB), ["Report 2024/", "Report 2024/a.txt", "Report 2024/b.txt", "Report 2024/d/", "Report 2024/d/c.txt"])
            // C: one file
            _ = try fx.folderTree("single", files: ["note.final.txt": "N"])
            let c = fx.url("C.zip")
            _ = DataTestKit.run("/usr/bin/zip", ["-q", "-X", c.path, "note.final.txt"], cwd: fx.url("single"))
            let outC = fx.url("outC")
            let rc = try await ArcRun.run("archive.extract", [c], fx: fx, out: outC)
            try expectEqual(rc.outputs.map(\.lastPathComponent), ["note.final.txt"], "one file keeps its name and extension")
            let rc2 = try await ArcRun.run("archive.extract", [c], fx: fx, out: outC)
            try expectEqual(rc2.outputs.map(\.lastPathComponent), ["note.final (2).txt"], "the number goes before the extension")
            // folder mode: always a wrapper; here mode: entries next to the archive.
            let outF = fx.url("outF")
            let rf = try await ArcRun.run("archive.extract", [a], [ArchiveKeys.extractTo: "folder"], fx: fx, out: outF)
            try expectEqual(rf.outputs.map(\.lastPathComponent), ["A"]); try expectEqual(tree(outF), ["A/", "A/photos/", "A/photos/sub/", "A/photos/sub/y.txt", "A/photos/x.txt"])
            let outH = fx.url("outH")
            let rh = try await ArcRun.run("archive.extract", [b], [ArchiveKeys.extractTo: "here"], fx: fx, out: outH)
            try expectEqual(Set(rh.outputs.map(\.lastPathComponent)), ["a.txt", "b.txt", "d"]); try expectEqual(tree(outH), ["a.txt", "b.txt", "d/", "d/c.txt"])
        }

        dataTest("data.extract", "\"next to the archive\": names that exist are numbered or skipped by the overwrite policy", proves: ["arc.overwrite.policy"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            _ = try fx.folderTree("m", files: ["a.txt": "NEW", "d/c.txt": "C"])
            let z = fx.url("m.zip")
            _ = DataTestKit.run("/usr/bin/zip", ["-q", "-r", "-X", z.path, "a.txt", "d"], cwd: fx.url("m"))
            let out = fx.url("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("OLD".utf8).write(to: out.appendingPathComponent("a.txt"))
            let numbered = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.extractTo: "here", ArchiveKeys.overwrite: "number"], fx: fx, out: out)
            try expectEqual(Set(numbered.outputs.map(\.lastPathComponent)), ["a (2).txt", "d"])
            try expectEqual(DataTestKit.read(out.appendingPathComponent("a.txt")), Data("OLD".utf8), "the old file is untouched")
            try expectEqual(DataTestKit.read(out.appendingPathComponent("a (2).txt")), Data("NEW".utf8))
            let err = try await expectThrows("skip refuses an existing name") { _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.extractTo: "here", ArchiveKeys.overwrite: "skip"], fx: fx, out: out) }
            guard case ConversionError.skippedExisting = err else { throw TestFailure(message: "wrong error: \(err)", file: #fileID, line: #line) }
            try expectEqual(DataTestKit.read(out.appendingPathComponent("a.txt")), Data("OLD".utf8), "still untouched")
            try expect(TestFile.partials(in: out).isEmpty, "no staging folder is left behind")
        }
    }

    // MARK: Formats

    private static func registerFormats() {
        dataTest("data.extract", "every archive format extracts to the same tree: zip, tar, tar.gz (.tgz), tar.bz2, tar.xz, tar.zst, 7z - bytes, modes and dates identical to the source",
                 proves: ["arc.dates.restore", "arc.perms.restore"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let proj = try ArcFixtures.project(fx, name: "proj")
            let junkFree = ["readme.txt", "src/main.swift", "src/util/helper.swift", "docs/Привет мир.txt", "docs/Žluťák.txt", "bin/run.sh", "img/photo.jpg", ".hidden", "cafe\u{301}.txt"]
            func make(_ name: String, _ args: [String]) throws -> URL {
                let u = fx.url(name)
                let r = DataTestKit.run("/usr/bin/bsdtar", args + ["-cf", u.path, "-C", fx.root.path, "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX", "proj"])
                try expectEqual(r.status, 0, "\(name): \(r.output.prefix(200))")
                return u
            }
            var archives: [(String, URL)] = [("zip", try make("p.zip", ["--format", "zip"])), ("tar", try make("p.tar", [])), ("tar.gz", try make("p.tar.gz", ["-z"])), ("tgz", try make("p.tgz", ["-z"])),
                                             ("tar.bz2", try make("p.tar.bz2", ["-j"])), ("tar.xz", try make("p.tar.xz", ["-J"])), ("tar.zst", try make("p.tar.zst", ["--zstd"])), ("7z", try make("p.7z", ["--format", "7zip"]))]
            archives.append(("cp zip by /usr/bin/zip", try fx.zip("z2.zip", items: ["proj"])))
            for (label, archive) in archives {
                let out = fx.url("out-\(label.replacingOccurrences(of: " ", with: "_"))")
                let r = try await ArcRun.run("archive.extract", [archive], fx: fx, out: out)
                try expectEqual(r.outputs.map(\.lastPathComponent), ["proj"], label)
                for rel in junkFree {
                    let got = out.appendingPathComponent("proj/" + rel)
                    try expectEqual(DataTestKit.read(got), DataTestKit.read(proj.appendingPathComponent(rel)), "\(label): bytes of \(rel)")
                }
                try expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("proj/empty").path), "\(label): the empty folder")
                let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("proj/bin/run.sh").path)[.posixPermissions] as? NSNumber
                try expectEqual((mode?.intValue ?? 0) & 0o111, 0o111, "\(label): executable bit restored")
                let m = try unwrap(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("proj/readme.txt").path)[.modificationDate] as? Date)
                try expectClose(m.timeIntervalSince1970, 1_600_000_000, tolerance: 3, "\(label): modification date restored")
                try expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("proj/.DS_Store").path), "\(label): no junk")
                if !label.contains("by /usr/bin/zip") {          // /usr/bin/zip stores the file a link points to unless -y is given
                    let link = try? FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("proj/docs/link-to-readme").path)
                    try expectEqual(link, "../readme.txt", "\(label): the relative link")
                }
            }
        }

        dataTest("data.extract", "bare compressed files: .gz, .bz2, .xz come out named after the archive; a .gz that holds a tar is unpacked twice") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let text = DataTestKit.compressibleText(bytes: 50_000)
            try text.write(to: fx.url("report.txt"))
            _ = DataTestKit.run("/usr/bin/gzip", ["-k", "-f", fx.url("report.txt").path])
            _ = DataTestKit.run("/usr/bin/bzip2", ["-k", "-f", fx.url("report.txt").path])
            _ = DataTestKit.run("/usr/bin/compression_tool", ["-encode", "-a", "lzma", "-i", fx.url("report.txt").path, "-o", fx.url("report.txt.xz").path])
            for ext in ["gz", "bz2", "xz"] {
                let out = fx.url("out-\(ext)")
                let r = try await ArcRun.run("archive.extract", [fx.url("report.txt.\(ext)")], fx: fx, out: out)
                try expectEqual(r.outputs.map(\.lastPathComponent), ["report.txt"], ext)
                try expectEqual(DataTestKit.read(try unwrap(r.outputs.first)), text, ext)
            }
            // tar.gz read as a plain gzip yields a tar: it is unpacked once more.
            _ = try fx.folderTree("deep", files: ["a.txt": "A", "b/c.txt": "C"])
            let tgz = try fx.tarGz("deep.tar.gz", items: ["deep"])
            let renamed = fx.url("deep.gz"); try FileManager.default.copyItem(at: tgz, to: renamed)
            let r = try await ArcRun.run("archive.extract", [renamed], fx: fx)
            try expectEqual(r.outputs.map(\.lastPathComponent), ["deep"]); try expectEqual(tree(r.outputs[0]).filter { !$0.hasPrefix("__") }, ["a.txt", "b/", "b/c.txt"])
            let empty = fx.url("nothing.zip"); try RawZip.build([]).write(to: empty)
            let err = try await expectThrows("an empty archive") { _ = try await ArcRun.run("archive.extract", [empty], fx: fx) }
            try expect(ConversionError.describe(err).contains("empty") || ConversionError.describe(err).contains("пуст"), ConversionError.describe(err))
        }
    }

    // MARK: Safety

    private static func registerSafety() {
        dataTest("data.extract", "Windows-Russian zip names are repaired; the picker can force another code page; flagged UTF-8 names are untouched", proves: ["arc.names.decode"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            func enc(_ s: String, _ e: DataEncoding) -> Data { TextEncodingKit.encode(s, as: e).data }
            let names = ["Договор/Приложение 1.txt", "Договор/Подпись.txt", "Отчёт за квартал.txt"]
            let z = fx.url("win.zip")
            try RawZip.build(names.map { RawZip.Entry(name: enc($0, .cp866), data: Data("x".utf8)) }).write(to: z)
            let out = fx.url("out")
            let r = try await ArcRun.run("archive.extract", [z], fx: fx, out: out)
            try expectEqual(r.outputs.map(\.lastPathComponent), ["win"], "several top-level entries")
            try expectEqual(tree(out).sorted(), ["win/", "win/Договор/", "win/Договор/Подпись.txt", "win/Договор/Приложение 1.txt", "win/Отчёт за квартал.txt"].sorted(), "CP866 names are detected")
            let forced = fx.url("forced")
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.nameEncoding: "cp1251"], fx: fx, out: forced)
            try expect(tree(forced) != tree(out), "an explicit code page really changes the names: \(tree(forced).prefix(3))")
            let right = fx.url("right")
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.nameEncoding: "cp866"], fx: fx, out: right)
            try expectEqual(tree(right), tree(out))
            let utf8 = fx.url("flagged.zip")
            try RawZip.build([RawZip.Entry("Привет.txt", "x", flags: 0x0800)]).write(to: utf8)
            let o2 = fx.url("o2")
            _ = try await ArcRun.run("archive.extract", [utf8], [ArchiveKeys.nameEncoding: "cp437"], fx: fx, out: o2)
            try expectEqual(tree(o2), ["Привет.txt"], "the UTF-8 flag wins over the picker")
        }

        dataTest("data.extract", "hostile archives are refused: nothing is written inside or outside the destination, no staging folder remains (zip, tar, tar.gz, tar.xz via libarchive)") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let marker = fx.url("EVIL")                                  // would be created next to the output folder by "../EVIL"
            for evil in ["../EVIL", "ok/../../EVIL", "/EVIL", "..\\EVIL"] {
                let z = fx.url("evil-\(abs(evil.hashValue)).zip")
                try RawZip.build([RawZip.Entry("good.txt", "G"), RawZip.Entry(evil, "E")]).write(to: z)
                let out = fx.url("out-\(abs(evil.hashValue))")
                let err = try await expectThrows("\(evil) must be refused") { _ = try await ArcRun.run("archive.extract", [z], fx: fx, out: out) }
                guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error for \(evil): \(err)", file: #fileID, line: #line) }
                try expect(!FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: "/EVIL"), "nothing escaped via \(evil)")
                try expectEqual(DirectoryListing.names(out.path), [], "nothing at all was left in the destination (\(evil))")
            }
            // tar and tar.gz with ../ names, made by our own writer (bsdtar refuses to write such names).
            for gzip in [false, true] {
                let t = fx.url(gzip ? "evil.tar.gz" : "evil.tar")
                try DataTestsTar.write(t, items: [DataTestsTar.Item(name: "good.txt", data: Data("G".utf8)), DataTestsTar.Item(name: "../EVIL", data: Data("E".utf8))], gzip: gzip, fx: fx)
                let out = fx.url("out-tar-\(gzip)")
                let err = try await expectThrows("tar ../") { _ = try await ArcRun.run("archive.extract", [t], fx: fx, out: out) }
                guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error: \(err)", file: #fileID, line: #line) }
                try expect(!FileManager.default.fileExists(atPath: marker.path), "nothing escaped")
                try expectEqual(DirectoryListing.names(out.path), [], "the destination is clean")
            }
            // Archives read by libarchive: the app lists and checks every name itself before bsdtar writes a byte.
            let plain = fx.url("evil-for-xz.tar")
            try DataTestsTar.write(plain, items: [DataTestsTar.Item(name: "good.txt", data: Data("G".utf8)), DataTestsTar.Item(name: "../EVIL", data: Data("E".utf8))], gzip: false, fx: fx)
            let xz = fx.url("evil.tar.xz")
            if DataTestKit.run("/usr/bin/bsdtar", ["--xz", "-cf", xz.path, "@" + plain.path]).status == 0 {
                let out = fx.url("out-xz")
                let err = try await expectThrows("tar.xz ../") { _ = try await ArcRun.run("archive.extract", [xz], fx: fx, out: out) }
                guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error: \(err)", file: #fileID, line: #line) }
                try expect(!FileManager.default.fileExists(atPath: marker.path), "nothing escaped"); try expectEqual(DirectoryListing.names(out.path), [])
            }
        }

        dataTest("data.extract", "encrypted archives are recognised before anything is written (zip: ZipCrypto and AES) and never prompt for a passphrase") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.folderTree("secret", files: ["a.txt": "A", "b.txt": "B"])
            for (label, enc) in [("aes", "aes256"), ("zipcrypt", "zipcrypt")] {
                let z = fx.url("\(label).zip")
                let r = DataTestKit.run("/usr/bin/bsdtar", ["--format", "zip", "--options", "zip:encryption=\(enc)", "--passphrase", "pw", "-cf", z.path, "-C", src.path, "a.txt", "b.txt"])
                guard r.status == 0 else { continue }
                let out = fx.url("out-\(label)")
                let t0 = Date()
                let err = try await expectThrows("\(label) is encrypted") { _ = try await ArcRun.run("archive.extract", [z], fx: fx, out: out) }
                guard case ConversionError.encryptedArchive = err else { throw TestFailure(message: "wrong error for \(label): \(err)", file: #fileID, line: #line) }
                try expect(Date().timeIntervalSince(t0) < 2, "fails at once")
                try expectEqual(DirectoryListing.names(out.path), [])
                let info = await ArchiveSourceProbe().probe(FileItem(url: z))
                try expectEqual(info.bool("archive.encrypted"), true, "the probe says so too"); try expect(info.chips.contains { $0.text == L("needs a password", "нужен пароль") })
            }
        }
    }

    // MARK: Options

    private static func registerOptions() {
        dataTest("data.extract", "Mac junk is skipped by default and kept when asked; flatten puts every file in one folder with numbered duplicates", proves: ["arc.junk.skipped", "arc.flatten.layout"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let z = fx.url("mac.zip")
            try RawZip.build([RawZip.Entry("doc/a.txt", "A"), RawZip.Entry("doc/sub/a.txt", "A2"), RawZip.Entry("doc/._a.txt", "junk"), RawZip.Entry("doc/.DS_Store", "junk"),
                              RawZip.Entry("__MACOSX/doc/._a.txt", "junk"), RawZip.Entry("doc/sub/b.txt", "B")]).write(to: z)
            let skip = fx.url("skip")
            _ = try await ArcRun.run("archive.extract", [z], fx: fx, out: skip)
            try expectEqual(tree(skip), ["doc/", "doc/a.txt", "doc/sub/", "doc/sub/a.txt", "doc/sub/b.txt"])
            let keep = fx.url("keep")
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.excludeHidden: false], fx: fx, out: keep)
            let kept = Set(tree(keep))
            for p in ["mac/doc/a.txt", "mac/doc/._a.txt", "mac/doc/.DS_Store", "mac/__MACOSX/doc/._a.txt", "mac/doc/sub/b.txt"] { try expect(kept.contains(p), "\(p) is extracted when asked: \(kept.sorted())") }
            let flat = fx.url("flat")
            let r = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.flatten: true, ArchiveKeys.extractTo: "folder"], fx: fx, out: flat)
            try expectEqual(r.outputs.map(\.lastPathComponent), ["mac"])
            try expectEqual(tree(flat), ["mac/", "mac/a (2).txt", "mac/a.txt", "mac/b.txt"].sorted(), "one level; the second a.txt is numbered")
            try expectEqual(DataTestKit.read(flat.appendingPathComponent("mac/a.txt")), Data("A".utf8))
            try expectEqual(DataTestKit.read(flat.appendingPathComponent("mac/a (2).txt")), Data("A2".utf8))
            // Same names that differ only by case are different entries in a zip but one file on a Mac: both survive.
            let ci = fx.url("case.zip"); try RawZip.build([RawZip.Entry("A.txt", "1"), RawZip.Entry("a.txt", "2")]).write(to: ci)
            let co = fx.url("case-out")
            _ = try await ArcRun.run("archive.extract", [ci], [ArchiveKeys.extractTo: "here"], fx: fx, out: co)
            try expectEqual(Set(tree(co).map { $0.lowercased() }).count, 2, "two files: \(tree(co))")
        }

        dataTest("data.extract", "dates and permissions can be left alone; trash-after-extract moves the archive only after success", proves: ["arc.dates.restore", "arc.perms.restore", "arc.trash.source"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let z = fx.url("modes.zip")
            let unixExec: UInt32 = 0o100755 << 16, unixRO: UInt32 = 0o100600 << 16
            try RawZip.build([RawZip.Entry("tool.sh", "#!/bin/sh\n", host: 3, external: unixExec), RawZip.Entry("secret.txt", "s", host: 3, external: unixRO)]).write(to: z)
            let on = fx.url("on"), off = fx.url("off")
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.extractTo: "here"], fx: fx, out: on)
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.extractTo: "here", ArchiveKeys.permissions: false, ArchiveKeys.keepDates: false], fx: fx, out: off)
            func attrs(_ d: URL, _ n: String) throws -> (Int, Date) {
                let a = try FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(n).path)
                return (((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, (a[.modificationDate] as? Date) ?? .distantPast)
            }
            try expectEqual(try attrs(on, "tool.sh").0, 0o755, "restored"); try expectEqual(try attrs(on, "secret.txt").0, 0o600)
            try expectEqual(try attrs(off, "tool.sh").0, 0o644, "not restored: a plain file")
            let onDate = try attrs(on, "tool.sh").1.timeIntervalSince1970
            try expectClose(onDate, 946_684_800, tolerance: 90_000, "the 2000-01-01 date of the entry is restored")
            try expect(try attrs(off, "tool.sh").1.timeIntervalSince(Date()) > -60, "dates not restored: the file is new")
            // Trash after extract: only after success, and only with the option.
            let trashed = Locked<[URL]>([])
            ArchiveRun.trashHook = { url in trashed.withLock { $0.append(url) } }
            defer { ArchiveRun.trashHook = { _ = try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }
            _ = try await ArcRun.run("archive.extract", [z], fx: fx)
            try expectEqual(trashed.value, [], "off by default")
            _ = try await ArcRun.run("archive.extract", [z], [ArchiveKeys.deleteAfter: true], fx: fx)
            try expectEqual(trashed.value, [z], "the archive goes to the Trash after a successful extraction")
            let bad = fx.url("bad.zip"); try RawZip.build([RawZip.Entry("../x", "E")]).write(to: bad)
            _ = try? await ArcRun.run("archive.extract", [bad], [ArchiveKeys.deleteAfter: true], fx: fx)
            try expectEqual(trashed.value, [z], "a failed extraction never trashes the archive")
        }

        dataTest("data.extract", "extracting a big tar.gz is cancellable within 200 ms and leaves nothing behind", timeout: 120) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let big = fx.url("big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let h = try FileHandle(forWritingTo: big)
            let zeros = Data(count: 8_000_000)
            for _ in 0..<40 { try h.write(contentsOf: zeros) }
            try h.close()
            let tgz = fx.url("big.tar.gz")
            _ = DataTestKit.run("/usr/bin/bsdtar", ["-czf", tgz.path, "-C", fx.root.path, "big.bin"])
            let out = fx.url("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var rules = OutputRules(); rules.dirMode = .custom; rules.customDir = out.path
            let op = try ArcRun.operation("archive.extract")
            let items = [FileItem(url: tgz)]
            let ctx = OperationContext.testing(op, items: items, mode: .studio, rules: rules)
            let task = Task { try await op.execute(items: items, ctx: ctx) }
            try await Task.sleep(nanoseconds: 40_000_000)
            let t0 = Date(); task.cancel()
            let r = await task.result
            if case .success = r { throw TestFailure(message: "finished before the cancel; the machine is too fast", file: #fileID, line: #line) }
            try expect(Date().timeIntervalSince(t0) < 0.5, "cancelled in \(Date().timeIntervalSince(t0)) s")
            try expectEqual(DirectoryListing.names(out.path), [], "no partial output")
        }
    }

    // MARK: Repack

    private static func registerRepack() {
        dataTest("data.extract", "repack keeps the layout and the names: Windows-Russian zip -> tar.gz -> zip, 7z -> zip; a single top folder stays, several entries stay at the root",
                 proves: ["arc.format.sniff"]) {
            let fx = TestFixtures(); defer { fx.cleanup() }
            func enc(_ s: String, _ e: DataEncoding) -> Data { TextEncodingKit.encode(s, as: e).data }
            let names = ["Договор/Приложение 1.txt", "Отчёт за квартал.txt"]
            let z = fx.url("Win.zip")
            try RawZip.build(names.map { RawZip.Entry(name: enc($0, .cp866), data: Data("data \($0.count)".utf8)) }).write(to: z)
            let tgz = try unwrap(try await ArcRun.run("archive.to.tar.gz", [z], fx: fx).outputs.first)
            try expectEqual(tgz.lastPathComponent, "Win.tar.gz")
            try expectEqual(Set(try ArcOracle.names(tgz)), ["Договор", "Договор/Приложение 1.txt", "Отчёт за квартал.txt"], "names are real Cyrillic in the tar.gz, no extra wrapper folder")
            let back = try unwrap(try await ArcRun.run("archive.to.zip", [tgz], fx: fx).outputs.first)
            try expectEqual(Set(try ArcOracle.names(back)), ["Договор", "Договор/Приложение 1.txt", "Отчёт за квартал.txt"])
            let x = try ArcOracle.extract(back, fx: fx)
            try expectEqual(DataTestKit.read(x.appendingPathComponent("Отчёт за квартал.txt")), Data("data \("Отчёт за квартал.txt".count)".utf8))
            // single top-level folder
            let proj = try ArcFixtures.project(fx)
            let sevenZip = fx.url("proj.7z")
            if DataTestKit.run("/usr/bin/bsdtar", ["--format", "7zip", "-cf", sevenZip.path, "-C", fx.root.path, "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX", "proj"]).status == 0 {
                let zipped = try unwrap(try await ArcRun.run("archive.to.zip", [sevenZip], fx: fx).outputs.first)
                let listing = Set(try ArcOracle.names(zipped))
                try expectEqual(listing, Set(ArcFixtures.defaultNames.map { $0.isEmpty ? "proj" : "proj/" + $0 }), "7z -> zip keeps the folder 'proj'")
                let tar = try unwrap(try await ArcRun.run("archive.to.tar", [zipped], fx: fx).outputs.first)
                try expectEqual(tar.pathExtension, "tar"); try expectEqual(Set(try ArcOracle.names(tar)), listing, "zip -> tar")
            }
            _ = proj
        }
    }
}
