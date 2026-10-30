import Foundation
import Combine

// Test support of the downloader module: a rig that runs the REAL download code against the FAKE yt-dlp of Tests/Fixtures/downloader.
//
// Safety net: the fake never opens a socket, but the app code calls `NetworkGate.authorize` first, and every self-test run sets `forbidAll`.
// The rig therefore switches `forbidAll` off for the duration of one test and refuses to start unless the located yt-dlp IS the fake
// (a real yt-dlp can never be reached with the gate open). Everything it changes is restored by `teardown()`.

enum DownloaderFixtures {
    /// Tests/Fixtures/downloader, found through the path of this source file (the project root is four folders up) or `SC_PROJECT` (set by build.sh).
    static func directory(file: StaticString = #filePath) throws -> URL {
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let candidates = [root.appendingPathComponent("Tests/Fixtures/downloader", isDirectory: true),
                          ProcessInfo.processInfo.environment["SC_PROJECT"].map { URL(fileURLWithPath: $0).appendingPathComponent("Tests/Fixtures/downloader", isDirectory: true) }]
            .compactMap { $0 }
        if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("fake-yt-dlp").path) }) { return hit }
        throw TestFailure(message: "the fixtures folder Tests/Fixtures/downloader was not found (looked in \(candidates.map(\.path)))", file: "\(file)", line: 0)
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory().appendingPathComponent(name)) }
    static func info(_ name: String) throws -> DownloadInfo { try YtDlpInfoParser.parse(json: data(name)) }
}

@MainActor
final class DownloadRig {
    let fx = TestFixtures(label: "dl")
    /// Folder with the fake `yt-dlp`, its JSON fixtures and `fake.env`.
    let toolDir: URL
    var tool: URL { toolDir.appendingPathComponent("yt-dlp") }
    let argvLog: URL
    let outDir: URL
    let audioDir: URL
    let registry = OperationRegistry()
    let runner: JobRunner
    let service = DownloadService.shared
    /// Replaces the real network layer of the tool manager for the whole test: an accidental install or update check can only reach this stub.
    let stub = StubHTTP()

    private struct Saved {
        var settings: SettingsData
        var forbidAll: Bool
        var hooks: DownloadService.Hooks
        var registry: OperationRegistry
        var runner: JobRunner?
        var http: DownloaderHTTP
        var roots: (video: URL, audio: URL)?
        var postProcess: DownloadPostProcess.Override?
        var diskOverride: (@Sendable (URL) -> Int64?)?
        var provider: @Sendable () -> SettingsData
    }
    private var saved: Saved
    private var env: [String: String] = [:]

    /// `extra` registers more operations in the rig's private registry (the job runner resolves operations there).
    init(env: [String: String] = [:], settings: (inout DownloaderSettings) -> Void = { _ in }) throws {
        saved = Saved(settings: AppSettings.shared.data, forbidAll: NetworkGate.forbidAll, hooks: service.hooks, registry: service.registry,
                      runner: service.runnerOverride, http: YtDlpToolManager.shared.http,
                      roots: DownloadFolders.rootsOverride, postProcess: DownloadPostProcess.override,
                      diskOverride: DiskSpaceGuard.availableOverride, provider: NetworkGate.settingsProvider)
        toolDir = fx.url("fake-tool")
        try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        let src = try DownloaderFixtures.directory()
        for name in try FileManager.default.contentsOfDirectory(atPath: src.path) where !name.hasPrefix("._") && name != "fake.env" {
            let dest = toolDir.appendingPathComponent(name == "fake-yt-dlp" ? "yt-dlp" : name)
            try FileManager.default.copyItem(at: src.appendingPathComponent(name), to: dest)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolDir.appendingPathComponent("yt-dlp").path)
        argvLog = fx.url("argv.log")
        outDir = try fx.makeDirectory("Movies out")
        audioDir = try fx.makeDirectory("Music out")
        runner = JobRunner(persistence: false, registry: registry, settings: AppSettings.shared)

        NetworkGate.forbidAll = false
        NetworkGate.settingsProvider = { AppSettings.shared.data }
        DownloadFolders.rootsOverride = (outDir, audioDir)
        DownloadPostProcess.override = nil
        DiskSpaceGuard.availableOverride = nil
        DownloadInfoCache.shared.clear()
        registry.register(DownloadCatalog.operations())
        service.registry = registry
        service.runnerOverride = runner
        service.hooks = DownloadService.Hooks()
        self.env = env.merging(["FAKE_YTDLP_ARGV_LOG": argvLog.path]) { a, _ in a }
        try writeEnv()
        // Settings carry the tool path and the language: any later settings change re-applies them, so they must live there.
        let fakePath = toolDir.appendingPathComponent("yt-dlp").path
        AppSettings.shared.update { s in
            s = SettingsData()
            s.language = .english
            s.toolPaths = ["ytdlp": fakePath]
            s.downloader.consentGiven = true
            s.downloader.folder = nil
            s.downloader.afterDownload = .keepOriginal
            settings(&s.downloader)
        }
        ToolLocator.shared.refresh()
        YtDlpToolManager.shared.http = stub
        YtDlpToolManager.shared.refresh()
        // The one hard guard: the located yt-dlp must be the fake, otherwise nothing may run with the network gate open.
        guard ToolLocator.shared.url(.ytdlp)?.standardizedFileURL.path == tool.standardizedFileURL.path else {
            teardown()
            throw TestFailure(message: "the located yt-dlp is not the fake tool; refusing to run", file: #fileID, line: #line)
        }
    }

    /// Replaces the fake's behaviour variables (see the header of fake-yt-dlp).
    func setEnv(_ pairs: [String: String]) throws {
        env = pairs.merging(["FAKE_YTDLP_ARGV_LOG": argvLog.path]) { a, _ in a }
        try writeEnv()
    }

    private func writeEnv() throws {
        let text = env.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        try text.write(to: toolDir.appendingPathComponent("fake.env"), atomically: true, encoding: .utf8)
    }

    func configure(_ change: @escaping (inout DownloaderSettings) -> Void) { AppSettings.shared.update { change(&$0.downloader) } }

    func teardown() {
        runner.cancelAll()
        ProcessRegistry.shared.killAll()
        AppSettings.shared.update { $0 = saved.settings }     // also restores the language and the tool paths
        NetworkGate.forbidAll = saved.forbidAll
        NetworkGate.settingsProvider = saved.provider
        service.hooks = saved.hooks
        service.registry = saved.registry
        service.runnerOverride = saved.runner
        YtDlpToolManager.shared.http = saved.http
        DownloadFolders.rootsOverride = saved.roots
        DownloadPostProcess.override = saved.postProcess
        DiskSpaceGuard.availableOverride = saved.diskOverride
        DownloadInfoCache.shared.clear()
        ToolLocator.shared.refresh()
        fx.cleanup()
    }

    /// Runs `body` with a fresh rig and always tears it down.
    static func with(env: [String: String] = [:], settings: (inout DownloaderSettings) -> Void = { _ in }, _ body: (DownloadRig) async throws -> Void) async throws {
        let rig = try DownloadRig(env: env, settings: settings)
        do { try await body(rig) } catch { rig.teardown(); throw error }
        rig.teardown()
    }

    // MARK: Driving jobs

    /// Starts a quick download and returns its job (fails the test when the service did not start one).
    func start(_ url: String, mode: DownloadMode = .bestForApple) async throws -> Job {
        let outcome = await service.start(url: URL(string: url)!, mode: mode)
        guard case .started(let job) = outcome else { throw TestFailure(message: "the download did not start: \(outcome)", file: #fileID, line: #line) }
        return job
    }

    func start(request: DownloadRequest) async throws -> Job {
        let outcome = await service.start(request: request)
        guard case .started(let job) = outcome else { throw TestFailure(message: "the download did not start: \(outcome)", file: #fileID, line: #line) }
        return job
    }

    func request(_ url: String, _ change: (inout DownloadRequest) -> Void = { _ in }) -> DownloadRequest {
        var r = DownloadRequest(url: URL(string: url)!, outputDirectory: outDir)
        r.after = .keepOriginal
        r.concurrentFragments = AppSettings.shared.data.downloader.fragments   // what the Studio form starts with (the schema default comes from Settings)
        change(&r)
        return r
    }

    func finish(_ job: Job, timeout: TimeInterval = 30) async throws {
        try await expectEventually(timeout: timeout) { job.state.isFinished }
    }

    /// Starts, waits and requires `.done`.
    func download(_ url: String, mode: DownloadMode = .bestForApple, timeout: TimeInterval = 30) async throws -> Job {
        let job = try await start(url, mode: mode)
        try await finish(job, timeout: timeout)
        try expectEqual(job.state, .done, "the job should finish: \(job.errorMessage ?? "") \(job.logText.suffix(600))")
        return job
    }

    // MARK: Looking at results

    /// One array of arguments per invocation of the fake (version probes included).
    func invocations() -> [[String]] {
        guard let text = try? String(contentsOf: argvLog, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "--- invocation\n").dropFirst().map { block in
            block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }
    func infoInvocations() -> [[String]] { invocations().filter { $0.contains("-J") } }
    func downloadInvocations() -> [[String]] { invocations().filter { $0.contains("--newline") } }

    /// Visible files directly in `dir`, names only.
    func names(in dir: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (dir ?? outDir).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    /// Hidden work areas next to the output.
    func workAreas(in dir: URL? = nil) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (dir ?? outDir).path)) ?? []).filter { $0.hasPrefix(DownloadWorkArea.prefix) }
    }
    /// Every file below `dir` (relative paths).
    func tree(_ dir: URL? = nil) -> [String] {
        let base = dir ?? outDir
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(String(u.path.dropFirst(base.path.count + 1)))
        }
        return out.sorted()
    }
}

/// Collects what a published property emitted (progress, stages) for later assertions.
@MainActor
final class Recorder<Value> {
    private(set) var values: [Value] = []
    private var cancellable: AnyCancellable?
    init<P: Publisher>(_ publisher: P) where P.Output == Value, P.Failure == Never {
        cancellable = publisher.sink { [weak self] in self?.values.append($0) }
    }
}

/// A stub network layer: serves canned bytes, records every request, never touches a socket.
final class StubHTTP: DownloaderHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return _requests }
    /// Bytes served for the checksum file and the tool.
    var checksums = Data()
    var payload = Data()
    var tag = "2026.11.01"
    var failDownload = false
    /// Sets a quarantine attribute on the downloaded file, like a browser would (the installer must clear it).
    var quarantine = true

    private func note(_ url: URL) { lock.lock(); _requests.append(url); lock.unlock() }

    func data(from url: URL) async throws -> Data { note(url); return checksums }
    func finalURL(of url: URL) async throws -> URL {
        note(url)
        return URL(string: "https://github.com/yt-dlp/yt-dlp/releases/tag/\(tag)")!
    }
    func download(from url: URL, to destination: URL, progress: @Sendable (Double) -> Void) async throws {
        note(url)
        if failDownload { throw ConversionError.message(L10n("stub: connection lost")) }
        try payload.write(to: destination)
        progress(0.5)
        if quarantine {
            let value = "0083;5f5e1000;Safari;"
            _ = destination.path.withCString { p in value.withCString { setxattr(p, "com.apple.quarantine", $0, strlen($0), 0, 0) } }
        }
        progress(1)
    }

    /// A checksum file in the real format for `payload` under the real asset name (other entries are noise).
    static func sums(for payload: Data, name: String = "yt-dlp_macos", hash: String? = nil) -> Data {
        let h = hash ?? sha256Hex(payload)
        return Data("\(String(repeating: "0", count: 63))1  yt-dlp\n\(h)  \(name)\n\(String(repeating: "0", count: 63))2 *yt-dlp_macos_legacy\n".utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        let tmp = AppPaths.makeTempDirectory(purpose: "sha").appendingPathComponent("blob")
        defer { AppPaths.removeTemp(tmp.deletingLastPathComponent()) }
        try? data.write(to: tmp)
        return (try? YtDlpToolManager.sha256(of: tmp)) ?? ""
    }

    /// A tiny executable that prints a version, standing in for a yt-dlp binary.
    static func fakeBinary(version: String) -> Data { Data("#!/bin/sh\n[ \"$1\" = \"--version\" ] && echo \(version)\nexit 0\n".utf8) }
}
