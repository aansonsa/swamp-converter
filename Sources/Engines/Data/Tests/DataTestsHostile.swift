import Foundation
import Darwin

// Hostile archives, part 2: what a crafted file can do to the app beyond a bad name. Every case here was a real hole or a crash found by the phase-9 review: numbers from the
// file that trap, a chain of links that leaves the folder, a hard link that aliases somebody's file, set-id bits, special files, bombs, a lost quarantine mark.

enum DataTestsHostile {
    // MARK: Raw builders (independent of TarWriter / ZipKit, so a bug in the writers cannot hide a hole in the readers)

    /// A 512-byte ustar header with a correct checksum. `size` may be written as a raw 12-byte field for the corrupt-size cases.
    private static func tarHeader(name: String, type: UInt8, link: String = "", size: Int = 0, rawSizeField: [UInt8]? = nil, mode: Int = 0o644) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ at: Int, _ s: String, _ max: Int) { for (i, c) in s.utf8.prefix(max).enumerated() { b[at + i] = c } }
        func octal(_ at: Int, _ v: Int, _ width: Int) { let s = String(v, radix: 8); put(at, String(repeating: "0", count: max(0, width - 1 - s.count)) + s, width - 1) }
        put(0, name, 100); octal(100, mode, 8); octal(108, 0, 8); octal(116, 0, 8)
        if let raw = rawSizeField { for (i, c) in raw.prefix(12).enumerated() { b[124 + i] = c } } else { octal(124, size, 12) }
        octal(136, 1_700_000_000, 12)
        b[156] = type
        put(157, link, 100); put(257, "ustar", 5); b[263] = 0x30; b[264] = 0x30
        for i in 148..<156 { b[i] = 0x20 }
        let sum = b.reduce(0) { $0 + Int($1) }
        put(148, String(repeating: "0", count: max(0, 6 - String(sum, radix: 8).count)) + String(sum, radix: 8), 6); b[154] = 0; b[155] = 0x20
        return b
    }

    private static func tar(_ blocks: [[UInt8]]) -> Data { Data(blocks.flatMap { $0 } + [UInt8](repeating: 0, count: 1024)) }

    private static func paxBlocks(_ records: [String: String]) -> [[UInt8]] {
        func record(_ k: String, _ v: String) -> [UInt8] {
            let body = " \(k)=\(v)\n"; var len = body.utf8.count + 1
            while String(len).utf8.count + body.utf8.count != len { len = String(len).utf8.count + body.utf8.count }
            return Array("\(len)\(body)".utf8)
        }
        var data = records.flatMap { record($0.key, $0.value) }
        let size = data.count
        data += [UInt8](repeating: 0, count: (512 - size % 512) % 512)
        return [tarHeader(name: "pax", type: UInt8(ascii: "x"), size: size), data.chunked(512)].flatMap { $0 is [UInt8] ? [$0 as! [UInt8]] : [] } + data.chunked(512)
    }

    private static func context() -> OperationContext {
        OperationContext(operationID: "x", mode: .studio, resolved: ResolvedOptions(values: OptionValues(), inactive: [], messages: []), outputRules: OutputRules(), settings: SettingsData())
    }

    private static func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    /// A one-entry ZIP whose central directory declares the given zip64 sizes (nothing else in it is valid data).
    private static func zipWithZip64Sizes(usize: UInt64, csize: UInt64) -> Data {
        var cd: [UInt8] = le(0x0201_4B50, 4) + le(0x0314, 2) + le(45, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4)
        cd += le(0xFFFF_FFFF, 4) + le(0xFFFF_FFFF, 4) + le(1, 2) + le(20, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0, 4) + le(0, 4)
        cd += [UInt8(ascii: "a")] + le(1, 2) + le(16, 2) + le(usize, 8) + le(csize, 8)
        let eocd: [UInt8] = le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(1, 2) + le(1, 2) + le(UInt64(cd.count), 4) + le(0, 4) + le(0, 2)
        return Data(cd + eocd)
    }

    static func register() {
        dataTest("data.hostile", "numbers that come out of a file never trap: saturating sums, impossible sizes and dates are refused or dropped, not crashed on") {
            try expectEqual(ArchiveMath.add(Int64.max, Int64.max), Int64.max)
            try expectEqual(ArchiveMath.sum([Int64.max, 1, Int64.max]), Int64.max)
            try expectEqual(ArchiveMath.add(5, 6), 11)
            for bad in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: 1e300), Date(timeIntervalSince1970: -1e300)] {
                try expect(ArchiveMath.seconds(bad) == nil, "no date for \(bad.timeIntervalSince1970)")
            }
            try expectEqual(ArchiveMath.seconds(Date(timeIntervalSince1970: 1_700_000_000.9)), 1_700_000_000)
            try expect(ArchiveMath.tarSize(-1) == nil && ArchiveMath.tarSize(Int.max) == nil && ArchiveMath.tarSize(1 << 51) == nil)
            try expectEqual(ArchiveMath.tarSize(1234), 1234)
            try expectEqual(ArchiveMath.tarSize(nil), 0)
        }

        dataTest("data.hostile", "a ZIP that declares absurd zip64 sizes is refused calmly (listing, probing and extracting) instead of crashing the app") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            for (label, u, c) in [("size", UInt64(Int64.max), UInt64(0)), ("compressed size", UInt64(0), UInt64(Int64.max)), ("both", UInt64.max, UInt64.max)] {
                let z = fx.url("evil-\(label.prefix(3)).zip"); try zipWithZip64Sizes(usize: u, csize: c).write(to: z)
                _ = try await expectThrows("zip64 \(label) lie") { _ = try ZipKit.list(z) }
                let stage = fx.url("zs-\(label.prefix(3))"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                _ = try await expectThrows("extract \(label) lie") { _ = try await ArchiveExtractor.extract(z, into: stage, format: .zip, options: ArchiveExtractOptions(), ctx: context(), progress: { _ in }) }
            }
        }

        dataTest("data.hostile", "a TAR with a negative, huge or base-256 size field, a pax size of Int64.max or a date of 1e300 is refused or read without a crash") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let base256Huge: [UInt8] = [0xFF] + [UInt8](repeating: 0xFF, count: 11)               // negative once decoded
            let base256Big: [UInt8] = [0x80, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            let cases: [(String, Data)] = [
                ("base-256 negative", tar([tarHeader(name: "a", type: UInt8(ascii: "0"), rawSizeField: base256Huge)])),
                ("base-256 huge", tar([tarHeader(name: "a", type: UInt8(ascii: "0"), rawSizeField: base256Big)])),
                ("pax size Int64.max", tar(paxBlocks(["size": "9223372036854775807"]) + [tarHeader(name: "a", type: UInt8(ascii: "0"), size: 1)])),
                ("pax size negative", tar(paxBlocks(["size": "-5"]) + [tarHeader(name: "a", type: UInt8(ascii: "0"), size: 1)])),
                ("pax mtime 1e300", tar(paxBlocks(["mtime": "1e300"]) + [tarHeader(name: "a", type: UInt8(ascii: "0"), size: 0)])),
                ("pax mtime nan", tar(paxBlocks(["mtime": "nan"]) + [tarHeader(name: "a", type: UInt8(ascii: "0"), size: 0)]))]
            for (label, bytes) in cases {
                let t = fx.url("h-\(label.hashValue.magnitude).tar"); try bytes.write(to: t)
                let stage = fx.url("hs-\(label.hashValue.magnitude)"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                // Either a calm error or a harmless extraction: what must not happen is a trap (the test run would die here).
                _ = try? await ArchiveExtractor.extract(t, into: stage, format: .tar, options: ArchiveExtractOptions(), ctx: context(), progress: { _ in })
                _ = await ArchiveSourceProbe().probe(FileItem(url: t))
            }
        }

        dataTest("data.hostile", "a chain of links (x -> . then y -> x/x/..) plus a hard link through it cannot read or copy a file outside the folder (app tar path and libarchive path)") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let secret = fx.url("secret.txt"); try Data("TOP SECRET".utf8).write(to: secret)
            let raw = fx.url("chain.tar")
            try tar([tarHeader(name: "x", type: UInt8(ascii: "2"), link: "."), tarHeader(name: "y", type: UInt8(ascii: "2"), link: "x/x/.."),
                     tarHeader(name: "loot", type: UInt8(ascii: "1"), link: "y/secret.txt"), tarHeader(name: "ok.txt", type: UInt8(ascii: "0"), size: 0)]).write(to: raw)
            func assertContained(_ dest: URL, _ label: String) throws {
                let fm = FileManager.default
                try expect(!fm.fileExists(atPath: dest.appendingPathComponent("loot").path) || (try? Data(contentsOf: dest.appendingPathComponent("loot"))) != Data("TOP SECRET".utf8), "\(label): the outside file was copied in")
                var st = stat()
                if lstat(dest.appendingPathComponent("y").path, &st) == 0 {
                    try expect(ConfinedPath.resolvesInside(root: dest.path, linkRelative: "y", target: (try? fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("y").path)) ?? ""), "\(label): the link y leaves the folder")
                }
                try expectEqual(try Data(contentsOf: secret), Data("TOP SECRET".utf8), "\(label): the secret is untouched")
            }
            let stage = fx.url("dest"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            _ = try? await ArchiveExtractor.extract(raw, into: stage, format: .tar, options: ArchiveExtractOptions(), ctx: context(), progress: { _ in })
            try assertContained(stage, "app tar path")
            // The libarchive route: the same entries through bsdtar and xz.
            let xz = fx.url("chain.tar.xz")
            let packed = DataTestKit.run("/usr/bin/bsdtar", ["--xz", "-cf", xz.path, "@" + raw.path])
            guard packed.status == 0, ArchiveFormat.resolve(xz) == .tarXz else { try skipTest("bsdtar cannot repack the fixture: \(packed.output)") }
            let stage2 = fx.url("dest2"); try FileManager.default.createDirectory(at: stage2, withIntermediateDirectories: true)
            // libarchive may refuse the archive outright (then the working folder is thrown away by the operation and nothing is placed) or extract it; if it extracts, the result must be clean.
            do {
                _ = try await ArchiveExtractor.extract(xz, into: stage2, format: .tarXz, options: ArchiveExtractOptions(), ctx: context(), progress: { _ in })
                try assertContained(stage2, "libarchive path")
            } catch is TestFailure { throw TestFailure(message: "libarchive path: the extracted tree is not clean", file: #fileID, line: #line) }
            catch {
                out("      libarchive refused the hostile archive: \(ConversionError.describe(error))")
            }
        }

        dataTest("data.hostile", "links alone (no hard link) that resolve outside are removed from a libarchive extraction while a harmless link stays") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let raw = fx.url("links.tar")
            try tar([tarHeader(name: "x", type: UInt8(ascii: "2"), link: "."), tarHeader(name: "y", type: UInt8(ascii: "2"), link: "x/x/.."), tarHeader(name: "abs", type: UInt8(ascii: "2"), link: "/etc"),
                     tarHeader(name: "fine", type: UInt8(ascii: "2"), link: "ok.txt"), tarHeader(name: "ok.txt", type: UInt8(ascii: "0"), size: 0)]).write(to: raw)
            let xz = fx.url("links.tar.xz")
            let packed = DataTestKit.run("/usr/bin/bsdtar", ["--xz", "-cf", xz.path, "@" + raw.path])
            guard packed.status == 0 else { try skipTest("bsdtar cannot repack the fixture: \(packed.output)") }
            let stage = fx.url("dest"); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let report = try await ArchiveExtractor.extract(xz, into: stage, format: .tarXz, options: ArchiveExtractOptions(), ctx: context(), progress: { _ in })
            var st = stat()
            func exists(_ n: String) -> Bool { lstat(stage.appendingPathComponent(n).path, &st) == 0 }
            try expect(exists("ok.txt") && exists("fine") && exists("x"), "the harmless entries are there")
            try expect(!exists("y") && !exists("abs"), "the links that leave the folder are gone")
            try expect(report.skipped.contains { $0.hasPrefix("y:") } && report.skipped.contains { $0.hasPrefix("abs:") }, "and the report says so: \(report.skipped)")
        }

        dataTest("data.hostile", "the clean-up pass removes outside-resolving links, aliases of outside files, pipes and sockets, and clears set-id bits; harmless links stay") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let outside = fx.url("outside.txt"); try Data("O".utf8).write(to: outside)
            let root = fx.url("tree"); try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: root.appendingPathComponent("sub/real.txt"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("good").path, withDestinationPath: "sub/real.txt")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("up").path, withDestinationPath: "..")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("abs").path, withDestinationPath: "/etc")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dot").path, withDestinationPath: ".")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("late").path, withDestinationPath: "dot/dot/..")     // resolves to the parent of root
            link(outside.path, root.appendingPathComponent("alias.txt").path)                                                                  // a second name for an outside file
            try Data("run".utf8).write(to: root.appendingPathComponent("suid"))
            chmod(root.appendingPathComponent("suid").path, 0o4755)
            mkfifo(root.appendingPathComponent("pipe").path, 0o644)
            let removed = ArchiveSafety.sanitizeTree(at: root)
            var st = stat()
            func exists(_ name: String) -> Bool { lstat(root.appendingPathComponent(name).path, &st) == 0 }
            try expect(exists("good") && exists("dot") && exists("sub/real.txt"), "harmless links and files stay: \(removed)")
            for gone in ["up", "abs", "late", "alias.txt", "pipe"] { try expect(!exists(gone), "\(gone) was not removed: \(removed)") }
            try expectEqual(try Data(contentsOf: outside), Data("O".utf8), "the outside file is untouched")
            lstat(root.appendingPathComponent("suid").path, &st)
            try expectEqual(Int(st.st_mode & 0o7777), 0o755, "set-user-id is cleared")
        }

        dataTest("data.hostile", "a decompression bomb is bounded: a derived cap from the free space, an explicit cap still works, and the message is calm") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            try expect(DiskReserve.reserve(forFree: 10 << 30) >= 512 << 20, "the reserve is at least 512 MB")
            try expect(DiskReserve.reserve(forFree: 2000 << 30) >= 40 << 30, "and 2% of a big volume")
            let derived = ExtractSink(root: fx.root, policy: ExtractionPolicy())
            try expect((derived.policy.maxTotalBytes ?? 0) > 0, "no cap was asked for: one is derived from the free space")
            if let free = DiskReserve.freeBytes(at: fx.root), let cap = derived.policy.maxTotalBytes { try expect(cap < free, "the cap leaves the reserve free") }
            let small = ExtractSink(root: fx.root, policy: { var p = ExtractionPolicy(); p.maxTotalBytes = 100; return p }())
            try small.addBytes(100)
            _ = try await expectThrows("101st byte") { try small.addBytes(1) }
            let huge = ExtractSink(root: fx.root, policy: { var p = ExtractionPolicy(); p.maxTotalBytes = 1 << 20; return p }())
            _ = try await expectThrows("a count that would overflow") { try huge.addBytes(Int.max) }
        }

        dataTest("data.hostile", "an archive marked 'downloaded from the internet' passes the mark on to the top level, folders and executables it contains") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let archive = fx.url("dl.zip"); try Data("zip".utf8).write(to: archive)
            let mark = "0083;5f5e1000;Safari;"
            guard setxattr(archive.path, ArchiveSafety.quarantineAttribute, mark, mark.utf8.count, 0, 0) == 0 else { try skipTest("this volume does not keep extended attributes") }
            let root = fx.url("out"); try FileManager.default.createDirectory(at: root.appendingPathComponent("App/sub"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("App/sub/tool")); chmod(root.appendingPathComponent("App/sub/tool").path, 0o755)
            ArchiveSafety.propagateQuarantine(from: archive, to: root)
            for p in ["App", "App/sub", "App/sub/tool"] { try expect(ArchiveSafety.quarantineValue(of: root.appendingPathComponent(p)) == Array(mark.utf8), "\(p) carries the mark") }
            let clean = fx.url("clean.zip"); try Data("zip".utf8).write(to: clean)
            let root2 = fx.url("out2"); try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true); try Data("x".utf8).write(to: root2.appendingPathComponent("f"))
            ArchiveSafety.propagateQuarantine(from: clean, to: root2)
            try expect(ArchiveSafety.quarantineValue(of: root2.appendingPathComponent("f")) == nil, "an unmarked archive marks nothing")
        }
    }
}

private extension Array where Element == UInt8 {
    func chunked(_ n: Int) -> [[UInt8]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}
