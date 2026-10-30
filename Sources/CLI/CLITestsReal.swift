import Foundation
import ImageIO
import PDFKit

/// The CLI on the REAL engines and as a real child process: oracles read the results back with independent readers, and the stdout contract is checked on the
/// bytes a shell would see.
enum CLITestsReal {
    private static func world(_ body: (TestFixtures) async throws -> Void) async throws {
        let fx = TestFixtures(label: "clireal")
        defer { fx.cleanup() }
        try await body(fx)
    }

    private static func realRun(_ args: [String]) async -> CLIResult {
        await CLIRig.run(args, environment: CLIEnvironment())
    }

    /// ImageIO's own opinion of a file: (uti, width, height).
    private static func imageFacts(_ url: URL) -> (type: String, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (type, w, h)
    }

    private static func needOperation(_ id: String) throws -> Operation {
        guard let op = OperationRegistry.shared.operation(id: id) else { try skipTest("\(id) is not registered in this build") }
        if case .unavailable(let reason, _) = op.availability(for: [], tools: .shared) { try skipTest("\(id) is unavailable: \(reason.en)") }
        return op
    }

    /// Runs the built binary (the one running this test) as a child process. Environment: an isolated home so nothing real is read or written.
    private static func runBinary(_ args: [String], home: URL, executable: String? = nil) async throws -> (code: Int32, stdout: String, stderr: String) {
        guard let exe = executable ?? Bundle.main.executablePath else { try skipTest("the test binary has no executable path") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["SWAMP_CONVERTER_HOME"] = home.appendingPathComponent("home").path
                env["SWAMP_CONVERTER_TMP"] = home.appendingPathComponent("tmp").path
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // The parent must close its copies of the write ends, or the readers never see the end of the stream.
                try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                let group = DispatchGroup()
                let box = Locked<(Data, Data)>((Data(), Data()))
                group.enter(); DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); box.withLock { $0.0 = d }; group.leave() }
                group.enter(); DispatchQueue.global().async { let d = err.fileHandleForReading.readDataToEndOfFile(); box.withLock { $0.1 = d }; group.leave() }
                p.waitUntilExit()
                group.wait()
                let (o, e) = box.value
                cont.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self)))
            }
        }
    }

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("cli.real", "convert PNG to JPEG with the real image engine: the output decodes as JPEG with the same size, is not a copy, and --set quality is monotonic") {
            _ = try needOperation("image.to.jpg")
            try await world { fx in
                let png = try fx.png("photo.png", width: 160, height: 120, pattern: .noise(seed: 7))
                let r = await realRun(["convert", png.path, "--op", "image.to.jpg", "--json", "--out", fx.url("out").path])
                try expectEqual(r.code, 0, r.stdout + r.stderr)
                let done = try unwrap(try r.event("done").first)
                let out = URL(fileURLWithPath: try unwrap((done["outputs"] as? [String])?.first))
                let facts = try unwrap(imageFacts(out))
                try expectEqual(facts.type, "public.jpeg"); try expectEqual(facts.width, 160); try expectEqual(facts.height, 120)
                try expectEqual(out.pathExtension, "jpg"); try expect(TestFile.magic(out, 3) == [0xFF, 0xD8, 0xFF], "JPEG magic bytes")
                try expect(try Data(contentsOf: out) != Data(contentsOf: png), "not a copy of the input")
                try expect(TestFile.exists(png), "the original is untouched")

                let shorthand = await realRun(["convert", png.path, "--op", "jpg", "--quiet", "--out", fx.url("out2").path])
                try expectEqual(shorthand.code, 0, "a target format works as --op: \(shorthand.stderr)")
                try expectEqual(try Data(contentsOf: URL(fileURLWithPath: try unwrap(shorthand.lines.first))), try Data(contentsOf: out), "same recipe, same bytes as the wheel's quick run")

                var sizes: [Int: Int64] = [:]
                for q in [15, 60, 95] {
                    let s = await realRun(["convert", png.path, "--op", "image.to.jpg", "--set", "img.quality=\(q)", "--quiet", "--out", fx.url("q\(q)").path])
                    try expectEqual(s.code, 0, s.stderr)
                    let file = URL(fileURLWithPath: try unwrap(s.lines.first))
                    try expectEqual(imageFacts(file)?.type, "public.jpeg")
                    sizes[q] = TestFile.size(file)
                }
                try expect(sizes[15]! < sizes[60]! && sizes[60]! < sizes[95]!, "lower quality, smaller file: \(sizes)")
                let typo = await realRun(["convert", png.path, "--op", "image.to.jpg", "--set", "img.qualty=50"])
                try expectEqual(typo.code, 2); try expect(typo.stderr.contains("img.quality"), "the nearest key is suggested: \(typo.stderr)")
                let high = await realRun(["convert", png.path, "--op", "image.to.jpg", "--set", "img.quality=500"])
                try expectEqual(high.code, 2); try expect(high.stderr.contains("1...100"), high.stderr)
            }
        }

        t.register("cli.real", "a PDF to PNG and to text with the real PDF engine, read back with PDFKit and ImageIO") {
            _ = try needOperation("pdf.to.png")
            try await world { fx in
                let pdf = try fx.pdf("doc.pdf", pages: 1)
                let r = await realRun(["convert", pdf.path, "--op", "pdf.to.png", "--quiet", "--out", fx.url("png").path])
                try expectEqual(r.code, 0, r.stderr)
                let png = URL(fileURLWithPath: try unwrap(r.lines.first))
                let facts = try unwrap(imageFacts(png))
                try expectEqual(facts.type, "public.png"); try expect(facts.width > 100 && facts.height > facts.width / 2, "a page-sized picture: \(facts)")
                if OperationRegistry.shared.operation(id: "pdf.to.txt") != nil {
                    let multi = try fx.pdf("multi.pdf", pages: 2)
                    let txt = await realRun(["convert", multi.path, "--op", "pdf.to.txt", "--quiet", "--out", fx.url("txt").path])
                    try expectEqual(txt.code, 0, txt.stderr)
                    let text = try String(contentsOf: URL(fileURLWithPath: try unwrap(txt.lines.first)), encoding: .utf8)
                    let words = Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
                    try expect(words.contains("Page") && words.contains("Привет") && words.contains("2"), "the words of both pages are in the text: \(text.prefix(120))")
                    let reference = PDFDocument(url: multi)?.string ?? ""
                    try expectEqual(Set(reference.split(whereSeparator: { $0.isWhitespace }).map(String.init)), words, "the same words as PDFKit reads")
                }
            }
        }

        t.register("cli.real", "the built binary as a child process: stdout carries only the contract (JSON lines or paths), errors go to stderr with the right exit code") {
            _ = try needOperation("image.to.jpg")
            try await world { fx in
                let home = try fx.makeDirectory("childhome")
                let png = try fx.png("child photo.png", width: 64, height: 48, pattern: .gradient)
                // list-ops: ONE JSON document on stdout.
                let ops = try await runBinary(["list-ops", "--json"], home: home)
                try expectEqual(ops.code, 0, ops.stderr)
                let lines = ops.stdout.split(separator: "\n").map(String.init)
                try expectEqual(lines.count, 1, "one line on stdout")
                let doc = try unwrap(CLIJSON.parseObject(lines[0]))
                try expect((doc["operations"] as? [[String: Any]] ?? []).contains { ($0["id"] as? String) == "image.to.jpg" })
                // convert --json: every stdout line is an event, the last is done.
                let conv = try await runBinary(["convert", png.path, "--op", "image.to.jpg", "--json", "--out", fx.url("child out").path], home: home)
                try expectEqual(conv.code, 0, conv.stdout + conv.stderr)
                let events = try conv.stdout.split(separator: "\n").map { line -> [String: Any] in
                    try unwrap(CLIJSON.parseObject(String(line)), "stdout line is not JSON: \(line)")
                }
                try expectEqual(events.last?["event"] as? String, "done")
                let produced = URL(fileURLWithPath: try unwrap((events.last?["outputs"] as? [String])?.first))
                try expectEqual(imageFacts(produced)?.type, "public.jpeg")
                // human mode: stdout is the path and nothing else.
                let human = try await runBinary(["convert", png.path, "--op", "image.to.jpg", "--out", fx.url("child out").path], home: home)
                try expectEqual(human.code, 0, human.stderr)
                let paths = human.stdout.split(separator: "\n").map(String.init)
                try expectEqual(paths.count, 1, human.stdout)
                try expect(paths[0].hasSuffix("child photo (2).jpg") && TestFile.exists(URL(fileURLWithPath: paths[0])), "collision-safe name: \(paths)")
                // errors
                let missing = try await runBinary(["convert", fx.url("none.png").path, "--op", "image.to.jpg"], home: home)
                try expectEqual(missing.code, 2); try expect(missing.stdout.isEmpty, "nothing on stdout: \(missing.stdout)"); try expect(missing.stderr.hasPrefix("swamp: "))
                let unknown = try await runBinary(["convert", "--json"], home: home)
                try expectEqual(unknown.code, 2); try expectEqual(unknown.stdout.split(separator: "\n").count, 1, "a JSON error line")
                let version = try await runBinary(["version"], home: home)
                try expectEqual(version.code, 0); try expect(version.stdout.hasPrefix("swamp "))
            }
        }

        t.register("cli.real", "started as `swamp` (the name install.sh links): the CLI runs without a verb check, no arguments is a usage error") {
            try await world { fx in
                guard let exe = Bundle.main.executablePath else { try skipTest("no executable path") }
                let home = try fx.makeDirectory("swamphome")
                let link = fx.url("swamp")
                do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: exe)) } catch { try skipTest("cannot create a symbolic link here: \(error)") }
                let none = try await runBinary([], home: home, executable: link.path)
                try expectEqual(none.code, 2, none.stderr); try expect(none.stdout.isEmpty, "no stdout for a usage error")
                let v = try await runBinary(["version", "--json"], home: home, executable: link.path)
                try expectEqual(v.code, 0, v.stderr)
                try expectEqual(try unwrap(CLIJSON.parseObject(v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))["name"] as? String, "swamp")
            }
        }

        t.register("cli.real", "list-ops, options and presets on the real catalogue answer without side effects") {
            try await world { _ in
                let before = OperationRegistry.shared.staticCount
                let list = await realRun(["list-ops", "--json", "--available"])
                try expectEqual(list.code, 0, list.stderr)
                let d = try unwrap(CLIJSON.parseObject(try unwrap(list.lines.first)))
                for op in try unwrap(d["operations"] as? [[String: Any]]) { try expectEqual(op["available"] as? Bool, true, op["id"] as? String ?? "?") }
                let presets = await realRun(["presets", "list", "--json"])
                try expectEqual(presets.code, 0, presets.stderr)
                let p = try unwrap(CLIJSON.parseObject(try unwrap(presets.lines.first)))
                try expectEqual(p["count"] as? Int, PresetStore.shared.all.count)
                for id in ["download.link", "link.best"] {
                    if OperationRegistry.shared.operation(id: id) != nil || OperationRegistry.shared.primaryOperation(forTarget: id) != nil {
                        let o = await realRun(["options", id, "--json"])
                        try expectEqual(o.code, 0, "\(id): \(o.stderr)")
                        let schema = try unwrap(CLIJSON.parseObject(try unwrap(o.lines.first)))
                        try expect((schema["fieldCount"] as? Int ?? 0) > 5, "the download schema has its knobs: \(schema["fieldCount"] ?? "-")")
                        break
                    }
                }
                try expectEqual(OperationRegistry.shared.staticCount, before, "running commands does not change the catalogue")
            }
        }
    }
}
