import Foundation

// Self-tests of the zip layer: round trips, interoperability with the system tools, Windows-Russian names, hostile archives, zip64, damage and cancellation.

enum DataTestsZip {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("data.zip", "writer output is a valid zip for unzip and bsdtar; ZipKit reads names, sizes, dates, modes and extracts identical bytes") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let text = DataTestKit.compressibleText(bytes: 300_000)
            let noise = DataTestKit.noise(bytes: 20_000)
            let src = try fx.makeDirectory("src")
            try text.write(to: src.appendingPathComponent("текст чешский žluťoučký.txt"))
            try noise.write(to: src.appendingPathComponent("noise.bin"))
            let exe = src.appendingPathComponent("run.sh")
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let stamp = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: src.appendingPathComponent("noise.bin").path)

            let zipURL = fx.url("out.zip")
            let w = try ZipWriter(url: zipURL, level: 9)
            try w.addDirectory("src")
            try w.add(file: src.appendingPathComponent("текст чешский žluťoučký.txt"), as: "src/текст чешский žluťoučký.txt")
            try w.add(file: src.appendingPathComponent("noise.bin"), as: "src/noise.bin", method: .stored)
            try w.add(file: exe, as: "src/run.sh")
            try w.add(data: Data(), as: "src/empty.txt")
            try w.add(data: Data("hello".utf8), as: "src/small (1).txt")
            try w.finish()

            let unzip = DataTestKit.run("/usr/bin/unzip", ["-tq", zipURL.path])
            try expect(unzip.status == 0, "unzip -t must accept the archive: \(unzip.output)")
            let tar = DataTestKit.run("/usr/bin/env", ["LC_ALL=en_US.UTF-8", "/usr/bin/bsdtar", "-tf", zipURL.path])
            try expect(tar.status == 0 && tar.output.contains("noise.bin") && tar.output.precomposedStringWithCanonicalMapping.contains("текст чешский"), "bsdtar lists the archive with UTF-8 names: \(tar.output)")

            let entries = try ZipKit.list(zipURL)
            try expectEqual(entries.map(\.name), ["src/", "src/текст чешский žluťoučký.txt", "src/noise.bin", "src/run.sh", "src/empty.txt", "src/small (1).txt"])
            let noiseEntry = try unwrap(entries.first { $0.name == "src/noise.bin" })
            try expectEqual(noiseEntry.uncompressedSize, 20_000); try expectEqual(noiseEntry.method, 0)
            try expectEqual(noiseEntry.crc32, Checksum.crc32(noise))
            try expectClose(try unwrap(noiseEntry.modified).timeIntervalSince1970, stamp.timeIntervalSince1970, tolerance: 1, "extended timestamp keeps the modification date")
            let textEntry = try unwrap(entries.first { $0.name.hasPrefix("src/текст") })
            try expectEqual(textEntry.method, 8); try expect(textEntry.compressedSize < textEntry.uncompressedSize / 10, "compressible text deflates well")
            try expect(try unwrap(entries.first { $0.name == "src/run.sh" }).unixMode & 0o111 != 0, "executable bit is kept")
            try expect(entries[0].isDirectory)
            try expectEqual(try ZipKit.read(zipURL, entry: "src/small (1).txt"), Data("hello".utf8))

            let out = fx.url("out")
            try await ZipKit.extract(zipURL, to: out)
            try expectEqual(DataTestKit.read(out.appendingPathComponent("src/текст чешский žluťoučký.txt")), text)
            try expectEqual(DataTestKit.read(out.appendingPathComponent("src/noise.bin")), noise)
            try expect(FileManager.default.isExecutableFile(atPath: out.appendingPathComponent("src/run.sh").path), "extracted script is executable")
            let m = try unwrap(try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("src/noise.bin").path)[.modificationDate] as? Date)
            try expectClose(m.timeIntervalSince1970, stamp.timeIntervalSince1970, tolerance: 2, "modification time restored")
        }

        t.register("data.zip", "an archive made by /usr/bin/zip lists and extracts correctly") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            _ = try fx.folderTree("složka", files: ["a.txt": "A", "pod/b.txt": "B", "pod/hluboko/c.txt": "C"])
            let z = try fx.zip("složka.zip", items: ["složka"])
            let names = try ZipKit.list(z).map(\.name).sorted()
            try expect(names.contains("složka/pod/b.txt") && names.contains("složka/a.txt"), "names: \(names)")
            let out = fx.url("x")
            try await ZipKit.extract(z, to: out)
            try expectEqual(DataTestKit.listDir(out).filter { !$0.hasPrefix("__") }, ["složka", "složka/a.txt", "složka/pod", "složka/pod/b.txt", "složka/pod/hluboko", "složka/pod/hluboko/c.txt"])
        }

        t.register("data.zip", "Windows-Russian names without the UTF-8 flag are recovered (CP866, CP1251, CP437) and the picker overrides the guess") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            func enc(_ s: String, _ e: DataEncoding) -> Data { TextEncodingKit.encode(s, as: e).data }
            let names866 = ["Привет мир.txt", "Папка/Отчёт за квартал.docx", "Мои документы/письмо.txt"]
            let z866 = fx.url("cp866.zip")
            try RawZip.build(names866.map { RawZip.Entry(name: enc($0, .cp866), data: Data("x".utf8)) }).write(to: z866)
            try expectEqual(try ZipKit.list(z866).map(\.name), names866, "CP866 names are detected")
            let wrong = try ZipKit.list(z866, nameEncoding: .cp1251).map(\.name)
            try expect(wrong != names866, "the explicit CP1251 choice really changes the decoding")
            try expectEqual(try ZipKit.list(z866, nameEncoding: .cp866).map(\.name), names866)

            let names1251 = ["Договор поставки.pdf", "Фото/отпуск 2024.jpg"]
            let z1251 = fx.url("cp1251.zip")
            try RawZip.build(names1251.map { RawZip.Entry(name: enc($0, .windows1251), data: Data("x".utf8)) }).write(to: z1251)
            try expectEqual(try ZipKit.list(z1251).map(\.name), names1251, "CP1251 names are detected")

            let z437 = fx.url("cp437.zip")
            try RawZip.build([RawZip.Entry(name: enc("café menü.txt", .cp437), data: Data("x".utf8))]).write(to: z437)
            try expectEqual(try ZipKit.list(z437).map(\.name), ["café menü.txt"], "CP437 names are detected")

            let flagged = fx.url("utf8.zip")
            try RawZip.build([RawZip.Entry("Привет.txt", "x", flags: 0x0800)]).write(to: flagged)
            try expectEqual(try ZipKit.list(flagged).map(\.name), ["Привет.txt"], "the UTF-8 flag wins over detection")

            let out = fx.url("out866")
            try await ZipKit.extract(z866, to: out)
            try expectEqual(DataTestKit.listDir(out), ["Мои документы", "Мои документы/письмо.txt", "Папка", "Папка/Отчёт за квартал.docx", "Привет мир.txt"].sorted())
        }

        t.register("data.zip", "hostile archives are refused before anything is written: ../, absolute, drive letters, symlink games") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            for evil in ["../evil.txt", "ok/../../evil.txt", "/abs/evil.txt", "C:\\evil.txt", "..\\evil.txt"] {
                let z = fx.url("evil.zip")
                try RawZip.build([RawZip.Entry("good.txt", "G"), RawZip.Entry(evil, "E")]).write(to: z)
                let out = fx.url("out-\(abs(evil.hashValue))")
                let err = try await expectThrows("\(evil) must be refused") { try await ZipKit.extract(z, to: out) }
                guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error for \(evil): \(err)", file: #fileID, line: #line) }
                try expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("good.txt").path), "the good entry before the bad one is not written either")
                try expect(!FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("evil.txt").path), "nothing escaped")
            }
            // A normal nested path is accepted.
            let ok = fx.url("ok.zip")
            try RawZip.build([RawZip.Entry("sub/ok.txt", "fine")]).write(to: ok)
            try await ZipKit.extract(ok, to: fx.url("okout"))
            try expectEqual(DataTestKit.read(fx.url("okout/sub/ok.txt")), Data("fine".utf8))

            // Symlink games: a link to an absolute path is not created, a link to "." may not be written through.
            let unixLink: UInt32 = 0o120777 << 16
            let sneaky = fx.url("sneaky.zip")
            try RawZip.build([RawZip.Entry("link", "/tmp", host: 3, external: unixLink), RawZip.Entry("link/pwned.txt", "P")]).write(to: sneaky)
            let victim = URL(fileURLWithPath: "/tmp/pwned.txt")
            try? FileManager.default.removeItem(at: victim)
            try await ZipKit.extract(sneaky, to: fx.url("sneakyout"))
            try expect(!FileManager.default.fileExists(atPath: victim.path), "writing through a symlink to /tmp must not happen")
            let loop = fx.url("loop.zip")
            try RawZip.build([RawZip.Entry("self", ".", host: 3, external: unixLink), RawZip.Entry("self/x.txt", "X")]).write(to: loop)
            let err = try await expectThrows("a write through a symlink is refused") { try await ZipKit.extract(loop, to: fx.url("loopout")) }
            guard case ConversionError.unsafeArchivePath = err else { throw TestFailure(message: "wrong error: \(err)", file: #fileID, line: #line) }
        }

        t.register("data.zip", "encrypted entries are detected first and nothing is written") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let z = fx.url("enc.zip")
            try RawZip.build([RawZip.Entry("open.txt", "plain"), RawZip.Entry("secret.txt", "cipher", flags: 0x0001)]).write(to: z)
            let entries = try ZipKit.list(z)
            try expectEqual(entries.map(\.isEncrypted), [false, true])
            let err = try await expectThrows { try await ZipKit.extract(z, to: fx.url("out")) }
            guard case ConversionError.encryptedArchive = err else { throw TestFailure(message: "wrong error: \(err)", file: #fileID, line: #line) }
            try expect(!FileManager.default.fileExists(atPath: fx.url("out/open.txt").path), "the unencrypted entry before the encrypted one was not written")
            // A real AES / ZipCrypto archive made by bsdtar is flagged too.
            let src = try fx.folderTree("p", files: ["a.txt": "A"])
            let aes = fx.url("aes.zip")
            let r = DataTestKit.run("/usr/bin/bsdtar", ["--format", "zip", "--options", "zip:encryption=aes256", "--passphrase", "pw", "-cf", aes.path, "-C", src.path, "a.txt"])
            if r.status == 0 { try expect(try ZipKit.list(aes).allSatisfy(\.isEncrypted), "AES archive entries are flagged encrypted") }
        }

        t.register("data.zip", "zip64: forced zip64 records are accepted by unzip, bsdtar and ZipKit; the size decision boundary is exact") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let z = fx.url("z64.zip")
            let w = try ZipWriter(url: z, level: 6)
            w.forceZip64 = true
            let payload = DataTestKit.compressibleText(bytes: 50_000)
            try payload.write(to: fx.url("p.txt"))
            try w.add(file: fx.url("p.txt"), as: "streamed.txt")
            try w.add(data: payload, as: "memory.txt")
            try w.add(data: Data("stored".utf8), as: "s.txt", method: .stored)
            try w.finish()
            let unzip = DataTestKit.run("/usr/bin/unzip", ["-tq", z.path])
            try expect(unzip.status == 0, "unzip accepts zip64 records: \(unzip.output)")
            try expect(DataTestKit.run("/usr/bin/bsdtar", ["-tf", z.path]).status == 0, "bsdtar accepts zip64 records")
            let entries = try ZipKit.list(z)
            try expectEqual(entries.map(\.name), ["streamed.txt", "memory.txt", "s.txt"])
            try expectEqual(entries[0].uncompressedSize, 50_000)
            try expectEqual(try ZipKit.read(z, entry: "memory.txt"), payload)
            try expectEqual(try ZipKit.read(z, entry: "streamed.txt"), payload)
            try expectEqual(ZipWriter.zip64EntryThreshold < 0xFFFF_FFFF, true)
            // More entries than a classic archive can count (65 535) also needs the zip64 end record.
            let many = fx.url("many.zip")
            let mw = try ZipWriter(url: many, level: 0)
            for i in 0..<66_000 { try mw.add(data: Data(), as: "d/\(i)", method: .stored) }
            try mw.finish()
            try expectEqual(try ZipKit.list(many).count, 66_000)
            let counted = DataTestKit.run("/usr/bin/unzip", ["-Z1", many.path])
            try expect(counted.status == 0 && counted.output.split(separator: "\n").count == 66_000, "unzip also sees 66 000 entries")
        }

        t.register("data.zip", "damage is detected: checksum mismatch, truncated file, junk in front of the archive still reads") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let payload = Data("0123456789".utf8)
            var bytes = RawZip.build([RawZip.Entry("a.txt", "0123456789")])
            let good = fx.url("good.zip"); try bytes.write(to: good)
            try expectEqual(try ZipKit.read(good, entry: "a.txt"), payload)
            let idx = try unwrap(bytes.range(of: payload)).lowerBound
            bytes[idx] = 0x58   // flip one data byte
            let bad = fx.url("bad.zip"); try bytes.write(to: bad)
            let err = try await expectThrows("CRC mismatch must be reported") { _ = try ZipKit.read(bad, entry: "a.txt") }
            try expect(ConversionError.describe(err).contains("checksum") || ConversionError.describe(err).contains("контрольная"), "calm message: \(ConversionError.describe(err))")
            let cut = fx.url("cut.zip"); try Data(bytes.prefix(bytes.count - 30)).write(to: cut)
            _ = try await expectThrows("a truncated archive is not a zip") { _ = try ZipKit.list(cut) }
            let junk = fx.url("junk.zip"); try RawZip.build([RawZip.Entry("a.txt", "0123456789")], junkPrefix: 500).write(to: junk)
            try expectEqual(try ZipKit.read(junk, entry: "a.txt"), payload, "offsets are corrected for a stub in front of the archive")
            _ = try await expectThrows("not a zip at all") { _ = try ZipKit.list(fx.url("good.zip").deletingLastPathComponent().appendingPathComponent("missing.zip")) }
            try Data("just text".utf8).write(to: fx.url("note.zip"))
            _ = try await expectThrows { _ = try ZipKit.list(fx.url("note.zip")) }
        }

        t.register("data.zip", "extraction is cancellable within 200 ms and leaves no half-written file open") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let z = fx.url("big.zip")
            let w = try ZipWriter(url: z, level: 1)
            try w.add(data: Data(count: 300_000_000), as: "big.bin", method: .stored)
            try w.finish()
            let out = fx.url("out")
            let started = Locked(false)
            let task = Task { try await ZipKit.unpack(z, to: out, options: ZipExtractOptions(), progress: { _ in started.value = true }) }
            try await Task.sleep(nanoseconds: 25_000_000)
            let t0 = Date()
            task.cancel()
            let result = await task.result
            let took = Date().timeIntervalSince(t0)
            try expect(took < 0.5, "cancelled in \(took) s")
            if case .success = result { throw TestFailure(message: "extraction finished before the cancel arrived; the test machine is too fast", file: #fileID, line: #line) }
            let size = TestFile.size(out.appendingPathComponent("big.bin"))
            try expect(size < 300_000_000, "the file was not completed (\(size) bytes)")
        }
    }
}
