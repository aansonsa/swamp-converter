import Foundation

// Self-tests of the downloader (suite "downloader"). Everything runs against JSON fixtures, a stub network layer and the FAKE yt-dlp of
// Tests/Fixtures/downloader: no test ever reaches the network or a real yt-dlp. The files:
//   DownloaderTests.swift          registry, helpers, the link-wheel structure test, oracle coverage
//   DownloaderTestsLinks.swift     link validation, info JSON parsing, friendly error messages
//   DownloaderTestsFormats.swift   quality ladder, format selection, argv golden tests, option mapping
//   DownloaderTestsProgress.swift  progress lines, the progress mapper, work areas, the info cache
//   DownloaderTestsTool.swift      checksums, install / update with a stub network layer, JS runtimes, consent gating
//   DownloaderTestsRuns.swift      full jobs against the fake tool: progress, stages, cancel, resume, playlists, sections, errors
//   DownloaderTestsRuns2.swift     more jobs: modes, cookies, subtitles, conversion stage, disk space

enum DownloaderTests {
    /// Oracle ids that some test proves (see `DownloadOracles`). Filled while the tests are registered.
    nonisolated(unsafe) static var claimed = Set<String>()

    /// Registers one test of the suite. `oracles` names the schema oracles this test proves.
    static func test(_ name: String, requires: [String] = [], oracles: [String] = [], timeout: TimeInterval = 90, _ body: @escaping SelfTestBody) {
        claimed.formUnion(oracles)
        SelfTestRegistry.shared.register("downloader", name, requires: requires, timeout: timeout, body)
    }

    static func register() {
        registerCatalog()
        registerLinks()
        registerInfo()
        registerMessages()
        registerFormats()
        registerArguments()
        registerMapping()
        registerProgress()
        registerWorkAreas()
        registerTool()
        registerService()
        registerRuns()
        registerRuns2()
        registerCoverage()
    }

    // MARK: Catalogue

    private static func registerCatalog() {
        // Structural acceptance: the link wheel offers exactly the five download modes, in order, for a YouTube link.
        test("the link wheel offers the five download modes for a public link and none for a private host") {
            let reg = OperationRegistry()
            reg.register(DownloadCatalog.operations())
            let link = LinkItem(url: URL(string: "https://www.youtube.com/watch?v=abc")!)
            try expectEqual(reg.linkEntries(links: [link]).map(\.id), ["link.best", "link.max", "link.universal", "link.audio.m4a", "link.audio.mp3"])
            try expectEqual(reg.linkEntries(links: [LinkItem(url: URL(string: "http://192.168.0.5/x")!)]).count, 0)
            try expect(reg.operation(id: "link.best")?.meta.usesNetwork == true, "link operations declare network use")
        }
        test("registration: the download presets are valid against the schema") {
            let reg = OperationRegistry()
            reg.register(DownloadCatalog.operations())
            let ids = DownloadPresets.builtins.map(\.id)
            try expect(ids.count >= 6 && Set(ids).count == ids.count, "built-in presets exist and have unique ids")
            let schema = DownloadSchemas.link()
            for p in DownloadPresets.builtins {
                try expectEqual(p.targetID, DownloadSchemas.linkID)
                for key in p.values.storage.keys { try expect(schema.field(key) != nil, "preset \(p.id) sets the unknown key \(key)") }
                let r = schema.resolve(layers: [p.values])
                try expectEqual(r.values.string(DownloadKeys.mode), p.values.string(DownloadKeys.mode), "preset \(p.id) keeps its mode after resolving")
            }
        }
    }

    // MARK: Oracle coverage (last test of the suite)

    private static func registerCoverage() {
        test("every field of the download schema has an oracle and every oracle is proven by a test of this suite") {
            let schema = DownloadSchemas.link()
            var missing: [String] = []
            for f in schema.allFields {
                guard let ids = DownloadOracles.all[f.key], !ids.isEmpty else { missing.append("\(f.key): not listed in DownloadOracles"); continue }
                if f.oracle.isEmpty { missing.append("\(f.key): the field has no .oracle(...)") }
                for id in ids where !claimed.contains(id) { missing.append("\(f.key): no test proves oracle \(id)") }
            }
            try expect(missing.isEmpty, "oracle gaps: \(missing.joined(separator: "; "))")
            let keys = Set(schema.allFields.map(\.key))
            for key in DownloadOracles.all.keys { try expect(keys.contains(key), "DownloadOracles names \(key), which is not in the schema") }
        }
    }
}
