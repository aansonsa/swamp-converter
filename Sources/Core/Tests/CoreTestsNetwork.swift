import Foundation

// Core self-tests, part 3: the network gate and the URL scheme.

enum CoreTestsNetwork {
    static func register() {
        let t = SelfTestRegistry.shared

        t.register("core.network", "the self-test run forbids the network entirely") {
            try expect(NetworkGate.forbidAll, "Harness must set forbidAll before any test runs")
            let err = try await expectThrows { try NetworkGate.authorize(.mediaDownload) }
            try expect(err is ConversionError)
        }

        t.register("core.network", "without consent nothing is authorised; with consent only the listed purposes are") {
            let saved = NetworkGate.forbidAll; let provider = NetworkGate.settingsProvider
            defer { NetworkGate.forbidAll = saved; NetworkGate.settingsProvider = provider; NetworkGate.clearActivity() }
            NetworkGate.forbidAll = false
            var s = SettingsData()
            func use(_ d: SettingsData) { NetworkGate.settingsProvider = { d } }
            use(s)
            try await expectThrows { try NetworkGate.authorize(.installYtDlp) }
            s.downloader.consentGiven = true
            use(s)
            try NetworkGate.authorize(.installYtDlp, host: "github.com")
            try NetworkGate.authorize(.mediaDownload, host: "youtube.com")
            try await expectThrows { try NetworkGate.authorize(.updateCheckYtDlp, userInitiated: false) }
            try NetworkGate.authorize(.updateCheckYtDlp, userInitiated: true)
            s.downloader.checkForUpdates = true
            use(s)
            try NetworkGate.authorize(.updateCheckYtDlp, userInitiated: false)
            try expectEqual(NetworkGate.recentActivity.map(\.host), ["github.com", "youtube.com", "", ""])
            try expect(NetworkGate.recentActivity.allSatisfy { !$0.host.contains("/") && !$0.host.contains("?") }, "only hosts are recorded")
        }

        t.register("core.network", "swampconverter://download parses, validates and round-trips") {
            func parse(_ s: String) -> Result<DownloadURLScheme.Request, LinkRejection> { DownloadURLScheme.parse(URL(string: s)!) }
            guard case .success(let ok) = parse("swampconverter://download?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc%26utm_source%3Dx&mode=max&title=Hello") else {
                throw TestFailure(message: "valid request must parse", file: #fileID, line: #line)
            }
            try expectEqual(ok.link.url.absoluteString, "https://www.youtube.com/watch?v=abc"); try expectEqual(ok.mode, .maximum); try expectEqual(ok.link.title, "Hello")
            if case .success(let r) = parse("swampconverter://download?url=https%3A%2F%2Fvimeo.com%2F1") { try expectEqual(r.mode, nil) } else { throw TestFailure(message: "no mode is fine", file: #fileID, line: #line) }
            if case .success(let r) = parse("swampconverter://download?url=https%3A%2F%2Fvimeo.com%2F1&mode=bogus") { try expectEqual(r.mode, nil, "unknown mode falls back to the default") }
            for bad in ["swampconverter://download", "swampconverter://download?url=javascript%3Aalert(1)", "swampconverter://download?url=file%3A%2F%2F%2Fetc%2Fpasswd",
                        "swampconverter://download?url=http%3A%2F%2F127.0.0.1%2Fx", "swampconverter://other?url=https%3A%2F%2Fa.com", "https://example.com/download?url=https://a.com"] {
                if case .success = parse(bad) { throw TestFailure(message: "must reject \(bad)", file: #fileID, line: #line) }
            }
            let made = try unwrap(DownloadURLScheme.make(link: URL(string: "https://www.youtube.com/watch?v=abc&t=5")!, mode: .universal))
            guard case .success(let back) = DownloadURLScheme.parse(made) else { throw TestFailure(message: "round trip", file: #fileID, line: #line) }
            try expectEqual(back.link.url.absoluteString, "https://www.youtube.com/watch?v=abc&t=5"); try expectEqual(back.mode, .universal)
            try expect(DownloadURLScheme.bookmarklet().hasPrefix("javascript:") && DownloadURLScheme.bookmarklet().contains("encodeURIComponent(location.href)"))
        }
    }
}
