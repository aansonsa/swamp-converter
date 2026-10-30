import Foundation
import CryptoKit

// Tests: checksums, the explicit install and update with a STUB network layer (no socket is ever opened), the update check, the guard of the
// real network layer, JavaScript runtimes. The installer writes into the isolated Application Support folder of the test run only.

@MainActor private func toolFile() -> URL { YtDlpToolManager.installURL }

/// Runs `body` with a stub network layer, consent given, the gate open and an empty tools folder; restores everything afterwards.
@MainActor
private func withStub(consent: Bool = true, forbid: Bool = false, checkForUpdates: Bool = false, _ body: (StubHTTP) async throws -> Void) async throws {
    guard AppPaths.supportDir.path.contains("selftest-") else { try skipTest("not running in an isolated home: refusing to touch the tools folder") }
    let manager = YtDlpToolManager.shared
    let saved = (http: manager.http, settings: AppSettings.shared.data, forbid: NetworkGate.forbidAll)
    let stub = StubHTTP()
    manager.http = stub
    NetworkGate.forbidAll = forbid
    NetworkGate.clearActivity()
    try? FileManager.default.removeItem(at: toolFile())
    ToolLocator.shared.setUserOverrides([:])
    AppSettings.shared.update { $0.downloader.consentGiven = consent; $0.downloader.checkForUpdates = checkForUpdates; $0.downloader.lastUpdateCheck = 0 }
    manager.refresh()
    func restore() {
        manager.http = saved.http
        NetworkGate.forbidAll = saved.forbid
        AppSettings.shared.update { $0 = saved.settings }
        try? FileManager.default.removeItem(at: toolFile())
        ToolLocator.shared.setUserOverrides([:])
        manager.refresh()
    }
    do { try await body(stub) } catch { restore(); throw error }
    restore()
}

private func quarantineSet(_ url: URL) -> Bool { url.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) } >= 0 }
private func permissions(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
private func toolsFolderContents() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.userToolsDir.path)) ?? []).sorted() }

extension DownloaderTests {
    static func registerTool() {
        // MARK: Pure helpers

        test("tool: SHA2-256SUMS is parsed, SHA-256 is streamed and exact, versions compare as numbers") {
            let sums = YtDlpToolManager.parseChecksums(String(data: try DownloaderFixtures.data("SHA2-256SUMS"), encoding: .utf8)!)
            try expectEqual(sums["yt-dlp"], String(repeating: "0", count: 63) + "1"); try expectEqual(sums["yt-dlp.exe"], String(repeating: "0", count: 63) + "2")
            try expectEqual(sums["yt-dlp_macos_legacy"], String(repeating: "0", count: 63) + "4", "the binary marker * is dropped")
            try expectEqual(sums["yt-dlp_macos"], nil, "a line whose hash is not 64 hex digits is ignored")
            let messy = YtDlpToolManager.parseChecksums("\n  \(String(repeating: "A", count: 64))\ttool  \nnot a hash  file\n\(String(repeating: "b", count: 64))\n\(String(repeating: "c", count: 63))  short\n")
            try expectEqual(messy, ["tool": String(repeating: "a", count: 64)], "upper case is lowered, junk lines are skipped")
            let fx = TestFixtures(label: "sha"); defer { fx.cleanup() }
            func hash(_ data: Data) throws -> String { let u = fx.url("blob"); try data.write(to: u); return try YtDlpToolManager.sha256(of: u) }
            try expectEqual(try hash(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            try expectEqual(try hash(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            var big = Data(count: 5_300_000); for i in stride(from: 0, to: big.count, by: 4093) { big[i] = UInt8(truncatingIfNeeded: i) }
            try expectEqual(try hash(big), SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined(), "a multi-chunk file hashes like one block")
            try expectEqual(try YtDlpToolManager.verify(file: fx.url("blob"), name: "x", checksums: ["x": try hash(big).uppercased()]), true, "case does not matter")
            try expectEqual(try YtDlpToolManager.verify(file: fx.url("blob"), name: "x", checksums: ["x": String(repeating: "0", count: 64)]), false)
            try expectEqual(try YtDlpToolManager.verify(file: fx.url("blob"), name: "y", checksums: ["x": try hash(big)]), false, "no entry for the asset: not verified")
            do { _ = try YtDlpToolManager.sha256(of: fx.url("missing")); throw TestFailure(message: "missing file hashed", file: #fileID, line: #line) } catch is ConversionError {}
            for (a, b, newer) in [("2026.10.21", "2026.10.9", true), ("2026.10.20", "2026.10.20", false), ("2026.10.20.123456", "2026.10.20", true), ("2025.12.31", "2026.01.01", false),
                                  ("2026.1.2", "2025.12.31", true), ("junk", "2026.10.20", false), ("2026.10.20", "", false)] {
                try expectEqual(YtDlpToolManager.isNewer(a, than: b), newer, "\(a) vs \(b)")
            }
            for ok in ["2026.10.20", "2026.10.20.123456"] { try expect(YtDlpToolManager.isValidTag(ok), ok) }
            for bad in ["latest", "../../x", "2026.10", "2026.10.20/../x", "v2026.10.20", "2026.10.20\n", "2026.10.20.123456789", ""] { try expect(!YtDlpToolManager.isValidTag(bad), bad) }
            for (v, expected) in [(nil, true), ("", true), ("2025.10.22", false), ("2025.11.12", true), ("2026.01.01", true)] as [(String?, Bool)] {
                try expectEqual(YtDlpToolManager.supportsJSRuntimesOption(version: v), expected, "version \(v ?? "nil")")
            }
        }

        test("tool: placing a verified file is atomic, executable and quarantine-free; an old copy is replaced in one step") {
            let fx = TestFixtures(label: "place"); defer { fx.cleanup() }
            let source = fx.url("download"); try Data("new".utf8).write(to: source)
            _ = source.path.withCString { p in "0083;1;Safari;".withCString { setxattr(p, "com.apple.quarantine", $0, strlen($0), 0, 0) } }
            let dest = fx.url("tools/deeper/yt-dlp")   // the folder does not exist yet
            try YtDlpToolManager.place(verified: source, at: dest)
            try expectEqual(try String(contentsOf: dest, encoding: .utf8), "new"); try expectEqual(permissions(dest), 0o755); try expect(!quarantineSet(dest), "quarantine cleared")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), ["yt-dlp"], "no staging file is left behind")
            try Data("newer".utf8).write(to: source)
            try YtDlpToolManager.place(verified: source, at: dest)
            try expectEqual(try String(contentsOf: dest, encoding: .utf8), "newer"); try expectEqual(permissions(dest), 0o755)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path), ["yt-dlp"])
        }

        // MARK: Install, update, update check (stub network)

        test("install: one explicit action downloads the release, verifies SHA-256, clears quarantine, sets 755 and finds the tool") {
            try await withStub { stub in
                let payload = StubHTTP.fakeBinary(version: "2026.11.01")
                stub.payload = payload; stub.checksums = StubHTTP.sums(for: payload); stub.tag = "2026.11.01"
                try expect(!YtDlpToolManager.shared.status.isInstalled || YtDlpToolManager.shared.status.source != .userFolder, "nothing of ours installed yet")
                let progress = Locked<[Double]>([])
                try await YtDlpToolManager.shared.install { p in progress.withLock { $0.append(p) } }
                let url = toolFile()
                try expectEqual(try Data(contentsOf: url), payload, "the verified bytes, unchanged")
                try expectEqual(permissions(url), 0o755); try expect(!quarantineSet(url), "the quarantine attribute set by the download is cleared")
                try expectEqual(toolsFolderContents(), ["yt-dlp"], "no staging or temp files in the tools folder")
                try expect(progress.value == progress.value.sorted() && progress.value.last == 1 && progress.value.count >= 3, "progress \(progress.value)")
                let urls = stub.requests.map(\.absoluteString)
                try expectEqual(urls.count, 3, "release page, checksums, tool: \(urls)")
                try expect(urls.allSatisfy { $0.hasPrefix("https://github.com/yt-dlp/yt-dlp/releases/") }, "only the official release: \(urls)")
                try expect(urls.contains("https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.01/SHA2-256SUMS") && urls.contains("https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.01/yt-dlp_macos"), "the pinned release: \(urls)")
                let status = YtDlpToolManager.shared.status
                try expectEqual(status.url?.standardizedFileURL.path, url.standardizedFileURL.path); try expectEqual(status.source, .userFolder)
                try expect(ToolLocator.shared.has(.ytdlp))
                let installed = await YtDlpToolManager.shared.installedVersion(); try expectEqual(installed, "2026.11.01")
                let event = try unwrap(NetworkGate.recentActivity.last, "the install is in the activity list")
                try expectEqual(event.purpose, .installYtDlp); try expectEqual(event.host, "github.com")
            }
        }

        test("install: a checksum mismatch, a missing checksum or a broken download leaves NO file and an old copy untouched") {
            try await withStub { stub in
                let payload = StubHTTP.fakeBinary(version: "2026.11.01")
                stub.payload = payload; stub.checksums = StubHTTP.sums(for: payload, hash: String(repeating: "a", count: 64))
                let err = try await expectThrows("a wrong checksum must stop the install") { try await YtDlpToolManager.shared.install() }
                try expect(ConversionError.describe(err).contains("checksum") || ConversionError.describe(err).contains("контрольной"), ConversionError.describe(err))
                try expectEqual(toolsFolderContents(), [], "nothing at all in the tools folder")
                try expect(!ToolLocator.shared.has(.ytdlp) || ToolLocator.shared.find(.ytdlp)?.source != .userFolder)
                // The checksum file has no entry for the tool.
                stub.checksums = Data("\(String(repeating: "0", count: 64))  yt-dlp\n".utf8)
                let missing = try await expectThrows { try await YtDlpToolManager.shared.install() }
                try expect(ConversionError.describe(missing).contains("no checksum") || ConversionError.describe(missing).contains("нет контрольной"), ConversionError.describe(missing))
                try expectEqual(toolsFolderContents(), [])
                // A download that breaks half way.
                stub.checksums = StubHTTP.sums(for: payload); stub.failDownload = true
                _ = try await expectThrows { try await YtDlpToolManager.shared.install() }
                try expectEqual(toolsFolderContents(), [])
                // An older copy survives a failed update byte for byte.
                stub.failDownload = false
                try FileManager.default.createDirectory(at: AppPaths.userToolsDir, withIntermediateDirectories: true)
                let old = StubHTTP.fakeBinary(version: "2026.01.01"); try old.write(to: toolFile())
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolFile().path)
                stub.checksums = StubHTTP.sums(for: payload, hash: String(repeating: "b", count: 64))
                _ = try await expectThrows { try await YtDlpToolManager.shared.install() }
                try expectEqual(try Data(contentsOf: toolFile()), old, "the old copy is untouched"); try expectEqual(toolsFolderContents(), ["yt-dlp"])
            }
        }

        test("install: nothing is requested while the network is switched off or consent is missing") {
            try await withStub(forbid: true) { stub in
                let off = try await expectThrows { try await YtDlpToolManager.shared.install() }
                try expect(ConversionError.describe(off).contains("switched off") || ConversionError.describe(off).contains("отключ"), ConversionError.describe(off))
                try expectEqual(stub.requests.count, 0)
            }
            try await withStub(consent: false) { stub in
                let err = try await expectThrows { try await YtDlpToolManager.shared.install() }
                try expect(ConversionError.describe(err).contains("Settings > Downloader") || ConversionError.describe(err).contains("Настройки > Загрузка"), ConversionError.describe(err))
                try expectEqual(stub.requests.count, 0, "no consent, no request")
                try expectEqual(toolsFolderContents(), [])
                _ = try await expectThrows { _ = try await YtDlpToolManager.shared.update() }
                try expectEqual(stub.requests.count, 0)
            }
        }

        test("update: verified like the install, only for the app's own copy and only when newer") {
            try await withStub { stub in
                _ = try await expectThrows("update before install") { _ = try await YtDlpToolManager.shared.update() }
                let v1 = StubHTTP.fakeBinary(version: "2026.10.01")
                stub.payload = v1; stub.checksums = StubHTTP.sums(for: v1); stub.tag = "2026.10.01"
                try await YtDlpToolManager.shared.install()
                stub.checksums = Data()   // would fail verification if an update were attempted now
                let same = try await YtDlpToolManager.shared.update()
                try expectEqual(same, .alreadyLatest(version: "2026.10.01"))
                let v2 = StubHTTP.fakeBinary(version: "2026.11.01")
                stub.payload = v2; stub.checksums = StubHTTP.sums(for: v2, hash: String(repeating: "c", count: 64)); stub.tag = "2026.11.01"
                _ = try await expectThrows("a bad checksum stops the update") { _ = try await YtDlpToolManager.shared.update() }
                try expectEqual(try Data(contentsOf: toolFile()), v1, "still the old tool")
                stub.checksums = StubHTTP.sums(for: v2)
                let result = try await YtDlpToolManager.shared.update()
                try expectEqual(result, .updated(from: "2026.10.01", to: "2026.11.01"))
                try expectEqual(try Data(contentsOf: toolFile()), v2); try expectEqual(permissions(toolFile()), 0o755); try expect(!quarantineSet(toolFile()))
                let shown = await YtDlpToolManager.shared.installedVersion(); try expectEqual(shown, "2026.11.01", "the version shown is the new one")
                try expectEqual(NetworkGate.recentActivity.last?.purpose, .updateCheckYtDlp)
                // What was verified is remembered, and a later change of the file on disk is noticed.
                let record = try unwrap(AppSettings.shared.data.downloader.verifiedInstall)
                try expectEqual(record.version, "2026.11.01")
                try expectEqual(record.sha256, try YtDlpToolManager.sha256(of: toolFile()), "the recorded hash is the hash of the installed file")
                let intact = await YtDlpToolManager.shared.installedMatchesVerifiedRecord(); try expectEqual(intact, true)
                let handle = try FileHandle(forWritingTo: toolFile()); try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0a])); try handle.close()
                let changed = await YtDlpToolManager.shared.installedMatchesVerifiedRecord(); try expectEqual(changed, false, "a modified file no longer matches what was verified")
            }
            // A copy managed elsewhere (Homebrew, PATH) is not touched: say who updates it.
            try await withStub { stub in
                let fx = TestFixtures(label: "brew"); defer { fx.cleanup() }
                let outside = fx.url("bin/yt-dlp"); try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try StubHTTP.fakeBinary(version: "2025.01.01").write(to: outside)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
                AppSettings.shared.update { $0.toolPaths = ["ytdlp": outside.path] }; YtDlpToolManager.shared.refresh()
                let err = try await expectThrows { _ = try await YtDlpToolManager.shared.update() }
                try expect(ConversionError.describe(err).contains("brew upgrade yt-dlp"), ConversionError.describe(err))
                try expectEqual(stub.requests.count, 0, "nothing was requested for a copy the app does not own")
            }
        }

        test("update check on use: opt-in, at most once a day, never counted as the person's own action") {
            try await withStub { stub in
                let v1 = StubHTTP.fakeBinary(version: "2026.10.01")
                stub.payload = v1; stub.checksums = StubHTTP.sums(for: v1); stub.tag = "2026.10.01"
                try await YtDlpToolManager.shared.install()
                stub.tag = "2026.12.01"
                let before = stub.requests.count
                let off = await YtDlpToolManager.shared.checkForUpdateIfDue()
                try expectEqual(off, nil, "off by default"); try expectEqual(stub.requests.count, before, "and no request at all")
                AppSettings.shared.update { $0.downloader.checkForUpdates = true }
                let now = Date()
                let found = await YtDlpToolManager.shared.checkForUpdateIfDue(now: now)
                try expectEqual(found, "2026.12.01"); try expectEqual(stub.requests.count, before + 1, "one small request")
                try expect(abs(AppSettings.shared.data.downloader.lastUpdateCheck - now.timeIntervalSince1970) < 1, "the check is remembered")
                try expectEqual(NetworkGate.recentActivity.last?.purpose, .updateCheckYtDlp)
                let again = await YtDlpToolManager.shared.checkForUpdateIfDue(now: now.addingTimeInterval(3600))
                try expectEqual(again, nil); try expectEqual(stub.requests.count, before + 1, "not twice in a day")
                stub.tag = "2026.10.01"
                let tomorrow = await YtDlpToolManager.shared.checkForUpdateIfDue(now: now.addingTimeInterval(90_000))
                try expectEqual(tomorrow, nil, "due again, but nothing newer"); try expectEqual(stub.requests.count, before + 2)
                AppSettings.shared.update { $0.downloader.consentGiven = false; $0.downloader.lastUpdateCheck = 0 }
                let noConsent = await YtDlpToolManager.shared.checkForUpdateIfDue(now: now.addingTimeInterval(200_000))
                try expectEqual(noConsent, nil); try expectEqual(stub.requests.count, before + 2, "no consent, no request")
                AppSettings.shared.update { $0.downloader.consentGiven = true }
                NetworkGate.forbidAll = true
                let gated = await YtDlpToolManager.shared.checkForUpdateIfDue(now: now.addingTimeInterval(300_000))
                try expectEqual(gated, nil); try expectEqual(stub.requests.count, before + 2, "the gate wins")
            }
            try await withStub(checkForUpdates: true) { stub in
                // A yt-dlp elsewhere on this Mac (Homebrew) is a real copy worth checking: "nothing installed" can only be seen on a Mac without one.
                guard ToolLocator.shared.find(.ytdlp) == nil else { return }
                let none = await YtDlpToolManager.shared.checkForUpdateIfDue()
                try expectEqual(none, nil, "no tool installed: nothing to check"); try expectEqual(stub.requests.count, 0)
            }
        }

        // MARK: The real network layer, without a network

        test("network layer: only https and the official GitHub hosts; local files exercise the code path offline") {
            for ok in ["github.com", "api.github.com", "GitHub.com", "objects.githubusercontent.com", "githubusercontent.com"] { try expect(URLSessionDownloaderHTTP.isAllowedHost(ok), ok) }
            for bad in ["evil.com", "github.com.evil.com", "notgithub.com", "xgithubusercontent.com", "githubusercontent.com.evil.io", "", "github.io"] { try expect(!URLSessionDownloaderHTTP.isAllowedHost(bad), bad) }
            try expect(!URLSessionDownloaderHTTP.isAllowedHost(nil))
            let net = URLSessionDownloaderHTTP()
            for bad in ["http://github.com/x", "https://example.com/x", "file:///etc/hosts", "ftp://github.com/x"] {
                _ = try await expectThrows("\(bad) must be refused before any request") { _ = try await net.data(from: URL(string: bad)!) }
                _ = try await expectThrows { _ = try await net.finalURL(of: URL(string: bad)!) }
            }
            let fx = TestFixtures(label: "http"); defer { fx.cleanup() }
            let file = fx.url("sums.txt"); try Data("hello".utf8).write(to: file)
            let local = URLSessionDownloaderHTTP(allowedSchemes: ["https", "file"])
            let got = try await local.data(from: file); try expectEqual(got, Data("hello".utf8))
            let copy = fx.url("copy.bin"); let seen = Locked<[Double]>([])
            try await local.download(from: file, to: copy) { p in seen.withLock { $0.append(p) } }
            try expectEqual(try Data(contentsOf: copy), Data("hello".utf8))
            var small = local; small.maxDataBytes = 3
            _ = try await expectThrows("an unexpectedly large answer is ignored") { _ = try await small.data(from: file) }
        }

        // MARK: JavaScript runtimes

        test("javascript runtimes: found by preference, versions checked against yt-dlp's minimums, advice is explicit") {
            let fx = TestFixtures(label: "js"); defer { fx.cleanup() }
            func script(_ dir: URL, _ name: String, _ version: String) throws {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let u = dir.appendingPathComponent(name)
                try Data("#!/bin/sh\necho '\(version)'\n".utf8).write(to: u)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            }
            // The runtimes are stand-in scripts reached through the user's tool overrides, so the result does not depend on this Mac.
            let dir = fx.url("js")
            for (name, version) in [("deno", "deno 1.46.3 (stable)"), ("node", "v20.11.1"), ("bun", "1.1.0"), ("qjs", "2024-01-13")] { try script(dir, name, version) }
            defer { ToolLocator.shared.setUserOverrides([:]); ToolLocator.shared.refresh() }
            ToolLocator.shared.setUserOverrides(["deno": dir.appendingPathComponent("deno").path, "node": dir.appendingPathComponent("node").path,
                                                 "bun": dir.appendingPathComponent("bun").path, "quickjs": dir.appendingPathComponent("qjs").path])
            ToolLocator.shared.refresh()
            let all = JSRuntimeDetector.detectAll()
            try expectEqual(all.map(\.kind), [.deno, .node, .bun, .quickjs], "preference order: deno, node, bun, quickjs")
            let node = all[1]
            try expectEqual(node.url.path, dir.appendingPathComponent("node").path); try expectEqual(node.argument, "node:\(node.url.path)")
            try expectEqual(all[2].argument, "bun:\(dir.appendingPathComponent("bun").path)"); try expectEqual(all[3].argument, "quickjs:\(dir.appendingPathComponent("qjs").path)")
            try expectEqual(JSRuntimeDetector.detect()?.kind, .deno, "the first one found is told to yt-dlp unless a better one is known")
            let best = try unwrap(JSRuntimeDetector.detectBest()); try expect(best.meetsMinimum)
            try expectEqual(best.runtime.kind, .node, "deno 1.46 is too old, so the next runtime that meets the minimum wins"); try expectEqual(best.runtime.version, "v20.11.1")
            try expectEqual(JSRuntimeDetector.versionNumbers("v20.11.1"), [20, 11, 1]); try expectEqual(JSRuntimeDetector.versionNumbers("deno 2.1.4 (stable, release, aarch64-apple-darwin)"), [2, 1, 4])
            try expectEqual(JSRuntimeDetector.versionNumbers("Bun 1.1.0"), [1, 1, 0]); try expectEqual(JSRuntimeDetector.versionNumbers("none"), [])
            func rt(_ k: JSRuntime.Kind, _ v: String?) -> JSRuntime { JSRuntime(kind: k, url: URL(fileURLWithPath: "/x/\(k.rawValue)"), version: v) }
            try expect(JSRuntimeDetector.meetsMinimum(rt(.deno, "deno 2.0.0")) && !JSRuntimeDetector.meetsMinimum(rt(.deno, "deno 1.46.3")))
            try expect(JSRuntimeDetector.meetsMinimum(rt(.node, "v20.0.0")) && !JSRuntimeDetector.meetsMinimum(rt(.node, "v19.9.0")))
            try expect(JSRuntimeDetector.meetsMinimum(rt(.bun, "1.0.31")) && !JSRuntimeDetector.meetsMinimum(rt(.bun, "1.0.30")))
            try expect(JSRuntimeDetector.meetsMinimum(rt(.quickjs, "2021")) && JSRuntimeDetector.meetsMinimum(rt(.node, nil)), "unknown versions are given the benefit of the doubt")
            // Advice: an explanation and an explicit, copyable route; nothing is installed by the app itself.
            try expect(JSRuntimeAdvice.explanation.en.contains("deno") && JSRuntimeAdvice.explanation.en.contains("JavaScript") && !JSRuntimeAdvice.explanation.ru.isEmpty)
            try expectEqual(JSRuntimeAdvice.installCommand, "brew install deno"); try expect(JSRuntimeAdvice.tooOld(.node).en.contains("node") && JSRuntimeAdvice.tooOld(.node).en.contains("brew install deno"))
            try expectEqual(YtDlpToolManager.shared.detectJSRuntime(), JSRuntimeDetector.detect())
        }
    }
}
