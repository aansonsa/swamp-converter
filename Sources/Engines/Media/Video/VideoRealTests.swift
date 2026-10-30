import Foundation

// Real runs on the smallest fixtures, read back with ffprobe / ffmpeg (spec/handbrake.md 5.4). Suite "video".
// Every schema field names an oracle id; a test that proves an oracle registers it here, and `VideoSchemaTests` fails any field whose oracle no test proves.

enum VideoOracles {
    static let proven = Locked<[String: String]>([:])
    static func prove(_ ids: [String], by test: String) { proven.withLock { for i in ids { $0[i] = test } } }
}

/// Fixtures generated once per self-test run and shared by the real-run tests (the isolated test home is removed when the run ends).
@MainActor
enum VTShared {
    static let fx = TestFixtures(label: "vidshared")
    private static var cache: [String: URL] = [:]

    static func get(_ key: String, _ make: (TestFixtures) throws -> URL) throws -> URL {
        if let u = cache[key], FileManager.default.fileExists(atPath: u.path) { return u }
        let u = try make(fx)
        cache[key] = u
        return u
    }

    static var clip: URL { get throws { try get("clip") { try VT.clip($0, "clip.mp4") } } }
    /// 3 s, 640x480, noisier: for size, rate and filter tests that need room.
    static var big: URL { get throws { try get("big") { try VT.clip($0, "big.mp4", seconds: 3, size: "640x480", noise: 2) } } }
    static var card: URL { get throws { try get("card") { try VT.card($0) } } }
    static var noisy: URL { get throws { try get("noisy") { try VT.make($0, "noisy.mp4", ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=2", "-vf", "noise=alls=28:allf=t", "-c:v", "libx264", "-crf", "10", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-an"]) } } }
}

enum VideoRealTests {
    static let ff = ["tool.ffmpeg"]

    static func reg(_ name: String, oracles: [String] = [], timeout: TimeInterval = 150, requires: [String] = ff, _ body: @escaping SelfTestBody) {
        VideoOracles.prove(oracles, by: name)
        SelfTestRegistry.shared.register("video", name, requires: requires, timeout: timeout, body)
    }

    static func register() {
        VideoRealFormatTests.register()
        VideoRealPictureTests.register()
        VideoRealFilterTests.register()
        VideoRealAudioTests.register()
        VideoRealTextTests.register()
        VideoRealMiscTests.register()
    }
}

extension VT {
    /// A fresh empty output folder inside the shared fixture root.
    @MainActor
    static func outRules() -> OutputRules {
        let dir = VTShared.fx.url("out-\(Util.hex8())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = OutputRules()
        r.dirMode = .custom; r.customDir = dir.path
        return r
    }

    /// Runs an operation in Studio mode (options exactly as given over the quick recipe) into a fresh folder; returns the first output and the result.
    @MainActor
    static func go(_ id: String = "video.to.mp4", _ input: URL, _ set: OptionValues = [:]) async throws -> (url: URL, result: OperationResult) {
        let r = try await run(id, input, set: set, mode: .studio, rules: outRules())
        guard let u = r.outputs.first else { throw TestFailure(message: "\(id) produced no output", file: #fileID, line: #line) }
        return (u, r)
    }

    /// Bytes of the file as text (lossy) for searching encoder signatures such as "x264 - core".
    static func containsText(_ url: URL, _ needle: String) -> Bool {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return d.range(of: Data(needle.utf8)) != nil
    }
}
