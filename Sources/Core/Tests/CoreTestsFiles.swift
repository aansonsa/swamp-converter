import Foundation
import AppKit

// Core self-tests, part 1: files, names, kinds, processes, localisation, wheel layout, links, hotkeys.
// Registered by CoreTests.register() (see CoreTests.swift).

enum CoreTestsFiles {
    static func register() {
        let t = SelfTestRegistry.shared

        // MARK: OutputPaths

        t.register("core.paths", "unique names count up: name.ext, name (2).ext, name (3).ext") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("out")
            try expectEqual(OutputPaths.unique(dir: dir, base: "photo", ext: "png").lastPathComponent, "photo.png")
            try Data().write(to: dir.appendingPathComponent("photo.png"))
            try expectEqual(OutputPaths.unique(dir: dir, base: "photo", ext: "png").lastPathComponent, "photo (2).png")
            try Data().write(to: dir.appendingPathComponent("photo (2).png"))
            try expectEqual(OutputPaths.unique(dir: dir, base: "photo", ext: "png").lastPathComponent, "photo (3).png")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("pages"), withIntermediateDirectories: false)
            try expectEqual(OutputPaths.uniqueDirectory(dir: dir, name: "pages").lastPathComponent, "pages (2)")
        }

        t.register("core.paths", "at launch, work folders older than a day are swept from the temp root; a younger one (a running command-line job) stays") {
            let old = AppPaths.makeTempDirectory(purpose: "crashed")
            let young = AppPaths.makeTempDirectory(purpose: "running")
            defer { AppPaths.removeTemp(young); AppPaths.removeTemp(old) }
            try Data("x".utf8).write(to: old.appendingPathComponent("big.tmp"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: old.path)
            let removed = AppPaths.sweepStaleTemp()
            try expect(removed >= 1, "the stale folder is counted")
            try expect(!FileManager.default.fileExists(atPath: old.path), "the stale folder is gone")
            try expect(FileManager.default.fileExists(atPath: young.path), "a fresh folder is never touched")
        }

        t.register("core.paths", "produceFile writes via a hidden .part and moves it into place; collisions never overwrite") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("out")
            var sawPartial = false
            let first = try await OutputPaths.produceFile(dir: dir, base: "a", ext: "txt") { tmp in
                try expect(OutputPaths.isInFlightName(tmp.lastPathComponent), "temp name must be hidden: \(tmp.lastPathComponent)")
                try expect(tmp.pathExtension == "txt", "temp keeps the real extension")
                try "one".write(to: tmp, atomically: false, encoding: .utf8)
                sawPartial = FileManager.default.fileExists(atPath: tmp.path)
            }
            try expect(sawPartial)
            try expectEqual(first.lastPathComponent, "a.txt")
            let second = try await OutputPaths.produceFile(dir: dir, base: "a", ext: "txt") { try "two".write(to: $0, atomically: false, encoding: .utf8) }
            try expectEqual(second.lastPathComponent, "a (2).txt")
            try expectEqual(try String(contentsOf: first, encoding: .utf8), "one")
            try expectEqual(TestFile.partials(in: dir), [])
        }

        t.register("core.paths", "an error or cancellation inside produceFile leaves no partial file") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("out")
            struct Boom: Error {}
            try await expectThrows { _ = try await OutputPaths.produceFile(dir: dir, base: "x", ext: "bin") { tmp in try Data([1]).write(to: tmp); throw Boom() } }
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
            let task = Task { () -> URL in
                try await OutputPaths.produceFile(dir: dir, base: "y", ext: "bin") { tmp in
                    try Data([1]).write(to: tmp)
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            task.cancel()
            _ = await task.result
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        }

        t.register("core.paths", "skip policy refuses to overwrite; template expansion cleans empty tokens") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("out")
            try "keep".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let err = try await expectThrows { _ = try await OutputPaths.produceFile(dir: dir, base: "a", ext: "txt", collision: .skip) { try "new".write(to: $0, atomically: false, encoding: .utf8) } }
            try expect(err is ConversionError, "skipped existing must be a ConversionError")
            try expectEqual(OutputPaths.expandTemplate("{name} ({suffix})", tokens: ["name": "clip", "suffix": "small"]), "clip (small)")
            try expectEqual(OutputPaths.expandTemplate("{name} ({suffix})", tokens: ["name": "clip", "suffix": ""]), "clip")
            try expectEqual(OutputPaths.expandTemplate("{name}-{res}", tokens: ["name": "clip", "res": "1080p"]), "clip-1080p")
            try expectEqual(Util.safeFileName("a/b:c"), "a-b-c")
            try expectEqual(Util.safeFileName("..."), "file")
        }

        t.register("core.paths", "output directory rules: same folder, subfolder, custom folder") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let src = FileItem(url: fx.url("pics/a.png"), isDirectory: false)
            try fx.makeDirectory("pics")
            var rules = OutputRules()
            try expectEqual(try OutputPaths.outputDirectory(for: src, rules: rules).lastPathComponent, "pics")
            rules.dirMode = .subfolder; rules.subfolderName = "Converted"
            let sub = try OutputPaths.outputDirectory(for: src, rules: rules)
            try expectEqual(sub.lastPathComponent, "Converted")
            try expect(FileManager.default.fileExists(atPath: sub.path), "subfolder is created")
            rules.dirMode = .custom; rules.customDir = fx.url("elsewhere").path
            try expectEqual(try OutputPaths.outputDirectory(for: src, rules: rules).lastPathComponent, "elsewhere")
        }

        t.register("core.paths", "OwnOutputs remembers produced files (watched-folder loop guard)") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let dir = try fx.makeDirectory("out")
            let out = try await OutputPaths.produceFile(dir: dir, base: "r", ext: "txt") { try "x".write(to: $0, atomically: false, encoding: .utf8) }
            try expect(OwnOutputs.shared.contains(out), "produced file registered")
            try expect(!OwnOutputs.shared.contains(dir.appendingPathComponent("foreign.txt")))
            OwnOutputs.shared.beginWriting(to: dir)
            try expect(OwnOutputs.shared.isWriting(in: dir))
            OwnOutputs.shared.endWriting(to: dir)
            try expect(!OwnOutputs.shared.isWriting(in: dir))
        }

        // MARK: Kinds and formats

        t.register("core.kind", "file kind detection by extension, aliases and double extensions") {
            func kind(_ n: String) -> FileKind { FileItem(url: URL(fileURLWithPath: "/tmp/\(n)"), isDirectory: false).kind }
            try expectEqual(kind("a.JPEG"), .image); try expectEqual(Formats.key(forName: "a.JPEG"), "jpg")
            try expectEqual(kind("a.heif"), .image); try expectEqual(kind("a.CR3"), .raw)
            try expectEqual(kind("a.mkv"), .video); try expectEqual(kind("a.m4a"), .audio)
            try expectEqual(kind("a.pdf"), .pdf); try expectEqual(kind("a.docx"), .document)
            try expectEqual(kind("a.pptx"), .slides); try expectEqual(kind("a.xlsx"), .spreadsheet)
            try expectEqual(kind("a.srt"), .subtitle); try expectEqual(kind("a.zip"), .archive)
            try expectEqual(Formats.key(forName: "backup.tar.gz"), "tar.gz"); try expectEqual(kind("backup.tar.gz"), .archive)
            try expectEqual(Formats.key(forName: "x.tgz"), "tar.gz")
            try expectEqual(Formats.baseName(forName: "backup.tar.gz"), "backup"); try expectEqual(Formats.baseName(forName: ".hidden"), ".hidden")
            try expectEqual(Formats.baseName(forName: "Folder.v2", isDirectory: true), "Folder.v2")
            try expectEqual(kind("noextension"), .other)
            try expectEqual(FileItem(url: URL(fileURLWithPath: "/tmp/dir"), isDirectory: true).kind, .folder)
        }

        t.register("core.kind", "unknown extensions fall back to the system type database (UTType)") {
            // .ts is listed explicitly; .m2ts / .dds / .opus-style names are not all listed: the UTType fallback must classify real types.
            let heic = FileItem(url: URL(fileURLWithPath: "/tmp/a.heics"), isDirectory: false)
            try expect(heic.kind == .image || heic.kind == .other, "must not crash on rare extensions")
            try expectEqual(Formats.kind(forType: .jpeg), .image); try expectEqual(Formats.kind(forType: .mpeg4Movie), .video)
            try expectEqual(Formats.kind(forType: .mp3), .audio); try expectEqual(Formats.kind(forType: .pdf), .pdf)
            try expectEqual(Formats.kind(forType: .zip), .archive); try expectEqual(Formats.kind(forType: .folder), .folder)
            let items = [FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false), FileItem(url: URL(fileURLWithPath: "/tmp/b.pdf"), isDirectory: false)]
            try expectEqual(WheelProfile.profile(for: items), .mixed)
            try expectEqual(WheelProfile.profile(for: [items[0]]), .image)
        }

        // MARK: ProcessRunner

        t.register("core.process", "arguments are never interpreted by a shell") {
            let out = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["a; echo INJECTED", "$(whoami)", "`id`"], captureStdout: true)
            try expectEqual(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "a; echo INJECTED $(whoami) `id`")
        }

        t.register("core.process", "stdout is streamed line by line, splitting on \\n and \\r (ffmpeg stats use \\r)") {
            let lines = Locked<[String]>([])
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/printf"), ["one\\rtwo\\nthree\\r\\nfour"], onStdoutLine: { l in lines.withLock { $0.append(l) } })
            try expectEqual(lines.value, ["one", "two", "three", "four"])
        }

        t.register("core.process", "a non-zero exit throws toolFailed with the stderr tail; allowNonZeroExit returns the code") {
            let err = try await expectThrows { _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom 1>&2; exit 3"]) }
            guard case ConversionError.toolFailed(_, let code, let detail) = err else { throw TestFailure(message: "wrong error \(err)", file: #fileID, line: #line) }
            try expectEqual(code, 3); try expect(detail.contains("boom"), "stderr tail in the message")
            let ok = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 2"], allowNonZeroExit: true)
            try expectEqual(ok.exitCode, 2)
        }

        t.register("core.process", "cancelling the task kills the process tree within 3 seconds") {
            let before = ProcessRegistry.shared.count
            let started = Date()
            let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 60 & wait"]) }
            try await Task.sleep(nanoseconds: 400_000_000)
            try expectEqual(ProcessRegistry.shared.count, before + 1, "the running process is registered")
            task.cancel()
            let result = await task.result
            if case .failure(let e) = result { try expect(e is CancellationError, "must throw CancellationError, got \(e)") } else { throw TestFailure(message: "cancelled run must not succeed", file: #fileID, line: #line) }
            try expect(Date().timeIntervalSince(started) < 3, "cancel took too long")
            try expectEqual(ProcessRegistry.shared.count, before, "process unregistered")
        }

        t.register("core.process", "suspend and resume stop and continue a process (queue pause)") {
            let ctl = ProcessControl()
            let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], control: ctl) }
            try await Task.sleep(nanoseconds: 300_000_000)
            ctl.suspend(); try expect(ctl.isSuspended)
            ctl.resume(); try expect(!ctl.isSuspended)
            ctl.cancel()
            _ = await task.result
        }

        t.register("core.process", "background runs are niced (utility QoS, nice 10)") {
            let out = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "ps -o nice= -p $$"], captureStdout: true, background: true, allowNetwork: true)   // not sandboxed: the sandbox forbids running ps
            let nice = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -99
            try expect(nice >= 5, "child nice value should be raised, got \(nice)")
        }

        // MARK: Localisation

        t.register("core.loc", "language setting switches strings and bumps the revision") {
            let loc = Loc.shared
            let original = loc.setting
            defer { loc.set(original) }
            loc.set(.english); try expectEqual(L("Cancel", "Отмена"), "Cancel")
            let r1 = loc.revision
            loc.set(.russian); try expectEqual(L("Cancel", "Отмена"), "Отмена")
            try expectEqual(L10n("Open", "Открыть").text, "Открыть")
            try expect(loc.revision != r1 || Thread.isMainThread, "revision changes on language change")
            loc.set(.system); loc.setSystemLanguageOverride(.ru)
            try expectEqual(L("a", "б"), "б"); loc.setSystemLanguageOverride(.en); try expectEqual(L("a", "б"), "a")
            loc.setSystemLanguageOverride(nil)
        }

        t.register("core.loc", "Russian plural categories one / few / many") {
            let loc = Loc.shared; let original = loc.setting; defer { loc.set(original) }
            loc.set(.russian)
            try expectEqual(Loc.files(1), "1 файл"); try expectEqual(Loc.files(2), "2 файла"); try expectEqual(Loc.files(5), "5 файлов")
            try expectEqual(Loc.files(11), "11 файлов"); try expectEqual(Loc.files(21), "21 файл"); try expectEqual(Loc.files(24), "24 файла")
            try expectEqual(Loc.files(112), "112 файлов"); try expectEqual(Loc.files(0), "0 файлов")
            loc.set(.english)
            try expectEqual(Loc.files(1), "1 file"); try expectEqual(Loc.files(2), "2 files")
            try expectEqual(L10n("{n} items", "{n} элементов").replacing(["n": "3"]).ru, "3 элементов")
        }

        t.register("core.util", "time parsing, formatting and natural sort") {
            try expectEqual(Util.parseTime("90"), 90); try expectEqual(Util.parseTime("1:30"), 90)
            try expectEqual(Util.parseTime("01:02:03.5"), 3723.5); try expectEqual(Util.parseTime("0,5"), 0.5)
            try expect(Util.parseTime("abc") == nil && Util.parseTime("") == nil && Util.parseTime("1:2:3:4") == nil)
            try expectEqual(Util.formatTime(3723), "1:02:03"); try expectEqual(Util.formatTime(65.25, fraction: true), "1:05.250")
            let sorted = Util.naturalSorted([URL(fileURLWithPath: "/p10"), URL(fileURLWithPath: "/p2"), URL(fileURLWithPath: "/p1")]).map(\.lastPathComponent)
            try expectEqual(sorted, ["p1", "p2", "p10"])
            try expectEqual(PageRange.parse("1-3, 5, 8-", pageCount: 9), [0, 1, 2, 4, 7, 8])
            try expect(PageRange.parse("0", pageCount: 5) == nil && PageRange.parse("3-1", pageCount: 5) == nil && PageRange.parse("9", pageCount: 5) == nil)
        }

        // MARK: Wheel layout

        t.register("core.layout", "hidden, order and favourites persist to disk and reload") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            let file = fx.url("layout.json")
            let layout = WheelLayout(fileURL: file, autosave: true)
            layout.setHidden(true, id: "b", wheel: .tools, profile: .image)
            layout.setOrder(["d", "c"], wheel: .tools, profile: .image)
            layout.setFavorite(true, id: "e")
            let reloaded = WheelLayout(fileURL: file, autosave: false)
            try expect(reloaded.isHidden("b", wheel: .tools, profile: .image))
            try expect(!reloaded.isHidden("b", wheel: .tools, profile: .pdf), "layouts are per profile")
            try expect(reloaded.isFavorite("e"))
            let ops = ["a", "b", "c", "d", "e"].map { id in OperationEntry(operation: EchoOp(id: id), availability: .available) }
            let arranged = reloaded.arrange(ops, wheel: .tools, profile: .image).map(\.id)
            try expectEqual(arranged, ["d", "c", "e", "a"], "explicit order first, then favourites, then catalogue order; hidden removed")
            reloaded.reset(wheel: .tools, profile: .image)
            try expectEqual(reloaded.arrange(ops, wheel: .tools, profile: .image).map(\.id), ["e", "a", "b", "c", "d"])
        }

        t.register("core.layout", "more than 8 operations split into a primary ring with More and a secondary ring") {
            let layout = WheelLayout(fileURL: URL(fileURLWithPath: "/dev/null"), autosave: false)
            let ops = (1...12).map { OperationEntry(operation: EchoOp(id: "op\($0)"), availability: .available) }
            let pages = layout.pages(ops)
            try expectEqual(pages.primary.count, 7); try expectEqual(pages.secondary.count, 5); try expect(pages.hasMore)
            try expectEqual(layout.pages(Array(ops.prefix(8))).secondary.count, 0)
            try expectEqual(layout.pages(ops + ops + ops).dropped, 36 - 7 - 8)
        }

        // MARK: Links

        t.register("core.links", "URLs are found in prose and stripped of trailing punctuation") {
            let urls = LinkParsing.extractURLs(from: "Look: https://example.com/a?b=1, and (https://example.org/x). Also <https://t.co/zz>! www.apple.com.")
            try expectEqual(urls.map(\.absoluteString), ["https://example.com/a?b=1", "https://example.org/x", "https://t.co/zz", "https://www.apple.com"])
            let wiki = LinkParsing.extractURLs(from: "https://en.wikipedia.org/wiki/Swamp_(film)")
            try expectEqual(wiki.first?.absoluteString, "https://en.wikipedia.org/wiki/Swamp_(film)")
            try expectEqual(LinkParsing.extractURLs(from: "no links here").count, 0)
            try expectEqual(LinkParsing.extractURLs(from: "https://a.com/x https://a.com/x").count, 1, "duplicates collapse")
        }

        t.register("core.links", "only public http(s) links are downloadable") {
            func ok(_ s: String) -> Bool { if case .success = LinkParsing.validate(s) { return true } else { return false } }
            try expect(ok("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
            try expect(ok("http://example.com/video.mp4"))
            try expect(ok("www.example.com/x"))
            for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "ftp://example.com/a", "ssh://host", "https://user:pw@example.com/",
                        "http://localhost:8080/", "http://127.0.0.1/x", "http://192.168.1.5/x", "http://10.0.0.2/", "https://intranet/", "https://printer.local/", "", "   ", "not a url"] {
                try expect(!ok(bad), "must reject: \(bad)")
            }
            if case .failure(let r) = LinkParsing.validate("javascript:alert(1)") { try expectEqual(r, .unsupportedScheme("javascript")) }
            if case .failure(let r) = LinkParsing.validate("file:///etc/passwd") { try expectEqual(r, .unsupportedScheme("file")) }
            try expect(LinkParsing.isPrivateHost("172.20.1.1") && !LinkParsing.isPrivateHost("172.32.1.1") && !LinkParsing.isPrivateHost("8.8.8.8"))
            try expect(LinkParsing.rejection(for: URL(string: "https://example.com/" + String(repeating: "a", count: 2100))!) == .tooLong)
        }

        t.register("core.links", "tracking parameters are stripped and youtu.be equals youtube.com/watch") {
            let a = try unwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ?si=abc&t=43"))
            let b = try unwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=x&feature=share"))
            let c = try unwrap(URL(string: "https://m.youtube.com/shorts/dQw4w9WgXcQ"))
            try expectEqual(LinkParsing.canonicalKey(of: a), "youtube:dQw4w9WgXcQ")
            try expectEqual(LinkParsing.canonicalKey(of: b), "youtube:dQw4w9WgXcQ")
            try expectEqual(LinkParsing.canonicalKey(of: c), "youtube:dQw4w9WgXcQ")
            try expectEqual(LinkParsing.normalized(a).absoluteString, "https://youtu.be/dQw4w9WgXcQ?t=43", "t= (start time) is kept, si= is dropped")
            try expectEqual(LinkParsing.normalized(try unwrap(URL(string: "https://Example.COM/p?fbclid=1&gclid=2&q=keep#frag"))).absoluteString, "https://example.com/p?q=keep")
            let links = LinkParsing.downloadableLinks(in: "https://youtu.be/dQw4w9WgXcQ and https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_medium=z")
            try expectEqual(links.count, 1, "same video twice is one link")
            try expectEqual(links[0].host, "youtu.be")
            try expectEqual(LinkParsing.displayHost(of: try unwrap(URL(string: "https://www.youtube.com/x"))), "youtube.com")
            if case .failure(let r) = LinkParsing.firstDownloadable(in: "see file:///tmp/x") { try expectEqual(r, .unsupportedScheme("file")) } else { throw TestFailure(message: "file: must fail", file: #fileID, line: #line) }
        }

        t.register("core.links", "InputItem, IncomingInput and DownloadMode / AfterDownload coding") {
            let l = LinkItem(url: URL(string: "https://youtu.be/abc")!, title: "Clip")
            let f = FileItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)
            let mixed: [InputItem] = [.file(f), .link(l)]
            try expectEqual(mixed.files.count, 1); try expectEqual(mixed.links.count, 1); try expectEqual(l.displayTitle, "Clip")
            try expectEqual(LinkItem(url: URL(string: "https://www.vimeo.com/1")!).displayTitle, "vimeo.com")
            let both = IncomingInput(files: [f], links: [l])
            try expect(both.prefersLinkWheel(preferLinks: true)); try expect(!both.prefersLinkWheel(preferLinks: false))
            try expect(IncomingInput(links: [l]).prefersLinkWheel(preferLinks: false)); try expect(!IncomingInput(files: [f]).prefersLinkWheel(preferLinks: true))
            try expectEqual(DownloadMode(parameter: "MAX"), .maximum); try expectEqual(DownloadMode(parameter: "audio"), .audioM4A); try expect(DownloadMode(parameter: "zzz") == nil)
            try expectEqual(DownloadMode.audioMP3.smartMode, nil); try expectEqual(DownloadMode.universal.smartMode, .universal)
            for a in [AfterDownload.keepOriginal, .bestForApple, .universal, .preset("u-123")] {
                let data = try JSONEncoder().encode(["x": a])
                try expectEqual(try JSONDecoder().decode([String: AfterDownload].self, from: data)["x"], a)
            }
            try expectEqual(String(decoding: try JSONEncoder().encode(["x": AfterDownload.preset("p")]), as: UTF8.self), "{\"x\":\"preset:p\"}")
        }

        // MARK: Hotkeys and scheduling

        t.register("core.hotkey", "defaults are Control-Option-Space and Control-Option-D; conflicts fall back to a free preset") {
            let s = SettingsData()
            try expectEqual(s.hotkey.combo.displayString, "\u{2303}\u{2325}Space"); try expectEqual(s.downloadHotkey.combo.displayString, "\u{2303}\u{2325}D")
            try expect(s.hotkey.combo.isUsable)
            let free = HotkeyPolicy.resolve(preferred: s.hotkey.combo, taken: [], candidates: HotkeyPresets.wheelFallbacks)
            try expectEqual(free, HotkeyPolicy.Resolution(combo: s.hotkey.combo, fellBack: false))
            let taken = HotkeyPolicy.resolve(preferred: s.hotkey.combo, taken: HotkeyPolicy.knownSystemCombos, candidates: HotkeyPresets.wheelFallbacks)
            try expectEqual(taken?.fellBack, true); try expect(taken?.combo != s.hotkey.combo)
            try expect(HotkeyPolicy.resolve(preferred: s.hotkey.combo, taken: Set([s.hotkey.combo] + HotkeyPresets.wheelFallbacks), candidates: HotkeyPresets.wheelFallbacks) == nil)
            try expect(!HotkeyCombo(keyCode: 13, modifiers: HotkeyModifier.shift).isUsable, "shift alone is not a shortcut")
        }

        t.register("core.scheduler", "concurrency adapts to cores, Low Power Mode and heat; background work waits on battery") {
            var env = SystemEnvironment(cores: 14, performanceCores: 10, thermal: .nominal, lowPowerMode: false, onBattery: false)
            try expectEqual(ResourcePolicy.maxConcurrent(requested: 2, env: env), 2)
            try expectEqual(ResourcePolicy.maxConcurrent(requested: 99, env: env), 10, "never above the performance cores")
            env.lowPowerMode = true; try expectEqual(ResourcePolicy.maxConcurrent(requested: 4, env: env), 2)
            env.lowPowerMode = false; env.thermal = .serious; try expectEqual(ResourcePolicy.maxConcurrent(requested: 4, env: env), 1)
            env.thermal = .nominal; env.cores = 4; env.performanceCores = nil; try expectEqual(ResourcePolicy.maxConcurrent(requested: 8, env: env), 2)
            try expect(!ResourcePolicy.preferHardwareEncoders(env: SystemEnvironment(cores: 8, thermal: .nominal)))
            try expect(ResourcePolicy.preferHardwareEncoders(env: SystemEnvironment(cores: 8, thermal: .nominal, lowPowerMode: false, onBattery: true)))
            try expect(ResourcePolicy.holdsBackgroundWork(env: SystemEnvironment(cores: 8, onBattery: true), pauseOnBattery: true))
            try expect(!ResourcePolicy.holdsBackgroundWork(env: SystemEnvironment(cores: 8, onBattery: true), pauseOnBattery: false))
            try expect(ResourcePolicy.isBackground(origin: .watch, mode: .automatic) && !ResourcePolicy.isBackground(origin: .wheel, mode: .quick))
            try expectEqual(ResourcePolicy.childNice(background: true), 10)
        }

        t.register("core.scheduler", "disk-space guard compares estimated output plus temp with free space") {
            let fx = TestFixtures(); defer { fx.cleanup() }
            DiskSpaceGuard.availableOverride = { _ in 10_000_000_000 }
            defer { DiskSpaceGuard.availableOverride = nil }
            try expectEqual(DiskSpaceGuard.check(estimatedOutput: 1_000_000_000, outputDir: fx.root).level, .ok)
            try expectEqual(DiskSpaceGuard.check(estimatedOutput: 9_500_000_000, outputDir: fx.root).level, .tight)
            let bad = DiskSpaceGuard.check(estimatedOutput: 12_000_000_000, outputDir: fx.root)
            try expectEqual(bad.level, .insufficient); try expect(bad.message != nil && !bad.isOK)
            let withTemp = DiskSpaceGuard.check(estimatedOutput: 6_000_000_000, tempBytes: 6_000_000_000, outputDir: fx.root, tempDir: fx.root)
            try expectEqual(withTemp.level, .insufficient, "same volume: output + temp must both fit")
        }

        t.register("core.scheduler", "the Dock icon follows open windows and the setting") {
            try expect(WindowPresence.desiredPolicy(openWindows: 0, showDockIcon: true) == .accessory)
            try expect(WindowPresence.desiredPolicy(openWindows: 2, showDockIcon: true) == .regular)
            try expect(WindowPresence.desiredPolicy(openWindows: 2, showDockIcon: false) == .accessory)
            WindowPresence.shared.opened("x"); WindowPresence.shared.closed("x")   // inert without an NSApplication delegate (self-test, CLI)
            try expectEqual(WindowPresence.shared.openCount, 0)
        }

        t.register("core.scheduler", "SleepGuard holds only while asked and releases at once") {
            SleepGuard.shared.release()
            try expect(!SleepGuard.shared.isHolding)
            SleepGuard.shared.hold(); try expect(SleepGuard.shared.isHolding)
            SleepGuard.shared.hold(); try expect(SleepGuard.shared.isHolding)
            SleepGuard.shared.release(); try expect(!SleepGuard.shared.isHolding)
        }
    }
}
