import Foundation

// TarKit against libarchive (bsdtar) and gzip: whatever one side writes, the other reads.

enum DataTestsTar {
    struct Item { var name: String; var data: Data; var mode: UInt32 = 0o644 }

    /// Writes `items` (and `dirs`, `links`) with TarWriter, optionally gzip-compressed.
    static func write(_ url: URL, items: [Item], dirs: [String] = [], links: [(String, String)] = [], gzip: Bool, fx: TestFixtures) throws {
        let out = try FDWriter(url: url)
        let deflater = gzip ? StreamDeflater(level: 6, window: 31) : nil
        let tar = TarWriter { chunk in if let deflater { try deflater.write(chunk) { try out.write($0) } } else { try out.write(chunk) } }
        for d in dirs { try tar.addDirectory(d, mtime: 1_700_000_000) }
        for (i, item) in items.enumerated() {
            let src = fx.url("tar-src-\(i)")
            try item.data.write(to: src)
            try tar.addFile(item.name, from: src, size: Int64(item.data.count), mode: item.mode, mtime: 1_700_000_000)
        }
        for (name, target) in links { try tar.addSymlink(name, target: target, mtime: 1_700_000_000) }
        try tar.finish()
        if let deflater { try deflater.finish { try out.write($0) } }
        try out.close()
    }

    /// Everything TarReader sees: name -> (kind, bytes).
    static func read(_ url: URL, gzip: Bool) throws -> [(entry: TarEntry, data: Data)] {
        var out: [(TarEntry, Data)] = []
        try TarReader.stream(try TarByteSource(url: url, gzip: gzip)) { entry, read in
            var d = Data()
            while true { let c = try read(1 << 16); if c.isEmpty { break }; d.append(contentsOf: c) }
            out.append((entry, d))
        }
        return out
    }

    static func register() {
        dataTest("data.tar", "TarWriter output is read by bsdtar: long and Cyrillic names, empty files, a 3 MB file, links, modes, plain and gzip") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let long = "very/" + String(repeating: "deep-folder-name/", count: 12) + "a-file-with-a-rather-long-name-\(String(repeating: "x", count: 40)).txt"
            let huge = String(repeating: "ы", count: 150)
            let big = DataTestKit.compressibleText(bytes: 3_000_000)
            let items = [Item(name: "plain.txt", data: Data("hello".utf8)), Item(name: "Привет мир/Отчёт.txt", data: Data("текст".utf8)), Item(name: long, data: Data("long".utf8)),
                         Item(name: huge + ".txt", data: Data("cyrillic".utf8)), Item(name: "empty.bin", data: Data()), Item(name: "big.txt", data: big),
                         Item(name: "run.sh", data: Data("#!/bin/sh\n".utf8), mode: 0o755)]
            for gzip in [false, true] {
                let tar = fx.url(gzip ? "w.tar.gz" : "w.tar")
                try write(tar, items: items, dirs: ["Привет мир", "emptydir"], links: [("link-to-plain", "plain.txt")], gzip: gzip, fx: fx)
                let list = DataTestKit.run("/usr/bin/bsdtar", ["-tvf", tar.path])
                try expectEqual(list.status, 0, "bsdtar lists the archive: \(list.output)")
                let names = Set(list.output.split(separator: "\n").map { String($0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(8).joined(separator: " ")) })
                for n in ["plain.txt", "Привет мир/Отчёт.txt", long, huge + ".txt", "empty.bin", "big.txt", "run.sh", "Привет мир/", "emptydir/"] { try expect(names.contains(n) || names.contains(where: { $0.hasPrefix(n) }), "bsdtar sees \(n.prefix(40))")  }
                try expect(list.output.contains("link-to-plain -> plain.txt"), "the link: \(list.output.suffix(300))")
                let out = fx.url(gzip ? "x-gz" : "x")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let x = DataTestKit.run("/usr/bin/bsdtar", ["-xf", tar.path, "-C", out.path])
                try expectEqual(x.status, 0, "bsdtar extracts: \(x.output)")
                for item in items { try expectEqual(DataTestKit.read(out.appendingPathComponent(item.name)), item.data, "bytes of \(item.name.prefix(30))") }
                let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber
                try expectEqual(mode?.intValue ?? 0, 0o755, "mode")
                try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("link-to-plain").path), "plain.txt")
                if gzip { try expectEqual(DataTestKit.run("/usr/bin/gzip", ["-t", tar.path]).status, 0, "gzip -t accepts the stream") }
                // And TarReader reads its own output.
                let back = try read(tar, gzip: gzip)
                try expectEqual(back.filter { $0.entry.kind == .file }.count, items.count)
                for item in items { try expectEqual(try unwrap(back.first { $0.entry.name == item.name }).data, item.data, item.name.prefix(30).description) }
                try expect(back.contains { $0.entry.kind == .directory && $0.entry.name == "Привет мир/" }, "directories")
                try expectEqual(back.first { $0.entry.kind == .symlink }?.entry.linkTarget, "plain.txt")
                try expectEqual(back.first { $0.entry.name == "run.sh" }?.entry.mode, 0o755)
                try expectEqual(back.first { $0.entry.name == "plain.txt" }?.entry.modified, Date(timeIntervalSince1970: 1_700_000_000))
            }
        }

        dataTest("data.tar", "TarReader reads archives made by bsdtar (pax and GNU formats, long and Unicode names) and by gzip-compressed multi-member streams") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = try fx.makeDirectory("src")
            let names = ["a.txt", "Папка с пробелами/файл №1.txt", "Žluťák/ďábel.txt", String(repeating: "dir/", count: 40) + "end.txt"]
            for n in names {
                let u = src.appendingPathComponent(n)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("content of \(n.count)".utf8).write(to: u)
            }
            for (label, args) in [("pax", ["--format", "pax"]), ("gnutar", ["--format", "gnutar"]), ("ustar", ["--format", "ustar"]), ("v7", ["--format", "v7tar"])] {
                if label == "ustar" || label == "v7" { continue }          // names this long / non-ASCII cannot be stored in these formats at all
                let tar = fx.url("\(label).tar")
                let r = DataTestKit.run("/usr/bin/bsdtar", args + ["-cf", tar.path, "-C", src.path, "a.txt", "Папка с пробелами", "Žluťák", "dir"])
                try expectEqual(r.status, 0, "bsdtar \(label): \(r.output)")
                let entries = try read(tar, gzip: false).filter { $0.entry.kind == .file }
                try expectEqual(Set(entries.map { $0.entry.name.precomposedStringWithCanonicalMapping }), Set(names.map { $0.precomposedStringWithCanonicalMapping }), label)
                for e in entries { try expectEqual(String(decoding: e.data, as: UTF8.self), "content of \(names.first { $0.precomposedStringWithCanonicalMapping == e.entry.name.precomposedStringWithCanonicalMapping }!.count)", label) }
            }
            // gzip -c of two separate tar halves concatenated is a valid multi-member gzip file that gunzip reads as one tar.
            let tar = fx.url("whole.tar")
            _ = DataTestKit.run("/usr/bin/bsdtar", ["--format", "pax", "-cf", tar.path, "-C", src.path, "a.txt"])
            let raw = try Data(contentsOf: tar)
            let cut = 512 * 3                                   // after header + padded data of a.txt, i.e. inside the stream, not at an entry edge necessarily
            let part1 = fx.url("p1"), part2 = fx.url("p2")
            try raw.prefix(cut).write(to: part1); try raw.dropFirst(cut).write(to: part2)
            _ = DataTestKit.run("/usr/bin/gzip", ["-k", "-f", part1.path]); _ = DataTestKit.run("/usr/bin/gzip", ["-k", "-f", part2.path])
            let joined = fx.url("joined.tar.gz")
            try (try Data(contentsOf: fx.url("p1.gz")) + (try Data(contentsOf: fx.url("p2.gz")))).write(to: joined)
            try expectEqual(try read(joined, gzip: true).filter { $0.entry.kind == .file }.map { $0.entry.name }, ["a.txt"], "two gzip members are one stream")
        }

        dataTest("data.tar", "damaged and hostile tar files fail calmly: bad checksum, truncation, ../ and absolute names, links that leave the folder") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let good = fx.url("good.tar")
            try write(good, items: [Item(name: "a.txt", data: Data(count: 2000))], gzip: false, fx: fx)
            var bad = try Data(contentsOf: good); bad[10] ^= 0xFF
            let badURL = fx.url("bad.tar"); try bad.write(to: badURL)
            _ = try await expectThrows("bad checksum") { _ = try read(badURL, gzip: false) }
            let cut = fx.url("cut.tar"); try Data(try Data(contentsOf: good).prefix(900)).write(to: cut)
            _ = try await expectThrows("truncated") { _ = try read(cut, gzip: false) }
            // Hostile names go into the sink and are refused there (nothing is written before the check of each name).
            for evil in ["../evil.txt", "ok/../../evil.txt", "/abs/evil.txt", "C:\\evil.txt"] {
                let t = fx.url("evil.tar")
                try write(t, items: [Item(name: evil, data: Data("E".utf8))], gzip: false, fx: fx)
                let stage = fx.url("stage-\(abs(evil.hashValue))")
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let ctx = OperationContext(operationID: "x", mode: .studio, resolved: ResolvedOptions(values: OptionValues(), inactive: [], messages: []), outputRules: OutputRules(), settings: SettingsData())
                let err = try await expectThrows("\(evil) must be refused") { _ = try await ArchiveExtractor.extract(t, into: stage, format: .tar, options: ArchiveExtractOptions(), ctx: ctx, progress: { _ in }) }
                guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error for \(evil): \(err)", file: #fileID, line: #line) }
                try expect(!FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("evil.txt").path), "nothing escaped")
            }
            // A link to /tmp followed by a file written through it: the link is not created, the file lands inside the folder or is refused.
            let linkTar = fx.url("link.tar")
            try write(linkTar, items: [Item(name: "link/pwned.txt", data: Data("P".utf8))], links: [("link", "/tmp")], gzip: false, fx: fx)
            try? FileManager.default.removeItem(atPath: "/tmp/pwned.txt")
            let stage = fx.url("linkstage"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let ctx = OperationContext(operationID: "x", mode: .studio, resolved: ResolvedOptions(values: OptionValues(), inactive: [], messages: []), outputRules: OutputRules(), settings: SettingsData())
            _ = try? await ArchiveExtractor.extract(linkTar, into: stage, format: .tar, options: ArchiveExtractOptions(), ctx: ctx, progress: { _ in })
            try expect(!FileManager.default.fileExists(atPath: "/tmp/pwned.txt"), "nothing was written through the link")
        }

        dataTest("data.tar", "format detection by content: a tar.gz named .zip, a zip named .tar, bare gzip, 7z and xz magic") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let tgz = fx.url("is-a-tgz.zip")
            try write(tgz, items: [Item(name: "a.txt", data: Data("A".utf8))], gzip: true, fx: fx)
            try expectEqual(ArchiveFormat.resolve(tgz), .tarGz, "gzip magic with a tar inside wins over the .zip name")
            try expectEqual(try ArchiveExtractor.gzipHoldsTar(tgz), true)
            let plain = fx.url("note.txt.gz"); try Data("just text".utf8).write(to: fx.url("note.txt")); _ = DataTestKit.run("/usr/bin/gzip", ["-k", "-f", fx.url("note.txt").path])
            try expectEqual(try ArchiveExtractor.gzipHoldsTar(plain), false); try expectEqual(ArchiveFormat.resolve(plain), .gz, "a bare gzip file stays a gzip file")
            let z = fx.url("real.tar"); try RawZip.build([RawZip.Entry("a.txt", "A")]).write(to: z)
            try expectEqual(ArchiveFormat.resolve(z), .zip, "zip magic wins over the .tar name")
            let tar = fx.url("t.tar"); try write(tar, items: [Item(name: "a.txt", data: Data("A".utf8))], gzip: false, fx: fx)
            try expectEqual(ArchiveFormat.resolve(tar), .tar)
            let src = try fx.makeDirectory("s"); try Data("x".utf8).write(to: src.appendingPathComponent("a"))
            for (flag, fmt, name) in [("--xz", ArchiveFormat.xz, "t.tar.xz"), ("--bzip2", .bz2, "t.tar.bz2"), ("--zstd", .zst, "t.tar.zst")] {
                _ = DataTestKit.run("/usr/bin/bsdtar", [flag, "-cf", fx.url(name).path, "-C", src.path, "a"])
                try expectEqual(ArchiveFormat.sniff(fx.url(name)), fmt, name)
            }
            _ = DataTestKit.run("/usr/bin/bsdtar", ["--format", "7zip", "-cf", fx.url("t.7z").path, "-C", src.path, "a"])
            try expectEqual(ArchiveFormat.sniff(fx.url("t.7z")), .sevenZip)
            try expectEqual(ArchiveFormat(key: Formats.key(forName: "x.tgz")), .tarGz); try expectEqual(ArchiveFormat(key: Formats.key(forName: "x.tbz2")), .tarBz2); try expectEqual(ArchiveFormat(key: Formats.key(forName: "x.txz")), .tarXz)
        }
    }
}
