import Foundation
import AppKit

/// Self-tests of the app shell (`./build.sh selftest app`). Nothing here opens a window, touches the real wheel, the real login item or the network: effects go through replaceable sinks.
enum AppTests {
    static func register() {
        let t = SelfTestRegistry.shared
        t.register("app", "the menu-bar glyph is a template image of a sensible size") {
            let img = MenuBarIcon.templateImage(pointSize: 18)
            try expect(img.isTemplate); try expect(img.size.height >= 11 && img.size.height <= 18 && img.size.width > 14 && img.size.width < 64, "\(img.size)")
        }
        registerRouter(t)
        registerServices(t)
        AppShellTests.register(t)
    }

    // MARK: URL router

    @MainActor
    static func tempFile(_ name: String = "a.png") throws -> (dir: URL, file: URL) {
        let dir = AppPaths.makeTempDirectory(purpose: "app-test")
        let file = dir.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        return (dir, file)
    }

    private static func registerRouter(_ t: SelfTestRegistry) {
        t.register("app.router", "files win over links; duplicates and remote hosts are dropped") {
            let a = URL(fileURLWithPath: "/tmp/x/a.png"), b = URL(fileURLWithPath: "/tmp/x/b.png")
            let link = URL(string: "https://example.com/v")!
            try expectEqual(URLRouter.route([a, link, b, a]), .files([a, b]))
            try expectEqual(URLRouter.route([URL(string: "file://server/share/x.png")!]), .ignored, "a file on another machine is not a local file")
            try expectEqual(URLRouter.route([]), .ignored)
        }
        t.register("app.router", "swampconverter://download is parsed, validated and never takes a path or a flag") {
            let ok = URL(string: "swampconverter://download?url=https%3A%2F%2Fexample.com%2Fwatch%3Fv%3D1&mode=audio-m4a")!
            guard case .download(let req) = URLRouter.route([ok]) else { throw TestFailure(message: "expected .download", file: #fileID, line: #line) }
            try expectEqual(req.link.url.host, "example.com")
            for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/x", "data:text/html,hi", "http://localhost/x", "http://192.168.0.2/x", "https://user:pw@example.com/x", "-o /tmp/evil"] {
                let enc = bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bad
                guard case .rejected = URLRouter.route([URL(string: "swampconverter://download?url=\(enc)")!]) else { throw TestFailure(message: "'\(bad)' must be rejected", file: #fileID, line: #line) }
            }
            guard case .rejected(.empty) = URLRouter.route([URL(string: "swampconverter://download")!]) else { throw TestFailure(message: "missing url must be rejected", file: #fileID, line: #line) }
            guard case .rejected = URLRouter.route([URL(string: "swampconverter://other?url=https%3A%2F%2Fexample.com")!]) else { throw TestFailure(message: "unknown action must be rejected", file: #fileID, line: #line) }
        }
        t.register("app.router", "plain links: valid ones become a link wheel, bad ones are rejected, other schemes are ignored") {
            let v1 = URL(string: "https://www.youtube.com/watch?v=abc&utm_source=x")!, v2 = URL(string: "https://youtu.be/abc")!, other = URL(string: "https://example.com/p")!
            guard case .links(let links) = URLRouter.route([v1, v2, other]) else { throw TestFailure(message: "expected .links", file: #fileID, line: #line) }
            try expectEqual(links.count, 2, "youtu.be/abc and watch?v=abc are the same video")
            try expect(!links[0].absoluteString.contains("utm_source"), "tracking noise is stripped")
            guard case .rejected(.privateHost) = URLRouter.route([URL(string: "http://127.0.0.1:8080/x")!]) else { throw TestFailure(message: "loopback must be rejected", file: #fileID, line: #line) }
            guard case .rejected(.credentialsInURL) = URLRouter.route([URL(string: "https://me:secret@example.com/x")!]) else { throw TestFailure(message: "credentials must be rejected", file: #fileID, line: #line) }
            // A mixed batch with one bad and one good link keeps the good one.
            guard case .links(let mixed) = URLRouter.route([URL(string: "http://localhost/x")!, other]) else { throw TestFailure(message: "good link must survive", file: #fileID, line: #line) }
            try expectEqual(mixed.count, 1)
            for ignored in ["javascript:alert(1)", "ftp://example.com/x", "mailto:a@b.c", "data:text/plain,hi", "x-apple.systempreferences:com.apple.x"] {
                try expectEqual(URLRouter.route([URL(string: ignored)!]), .ignored, ignored)
            }
        }
        t.register("app.router", "side effects: files go to the wheel, Option opens Studio, links to the link wheel, problems become one toast") {
            let (dir, file) = try tempFile()
            defer { AppPaths.removeTemp(dir) }
            let saved = URLRouter.sinks
            defer { URLRouter.sinks = saved }
            var log: [String] = []
            var option = false
            URLRouter.sinks = URLRouter.Sinks(
                presentFiles: { input, _ in log.append("wheel files=\(input.files.map(\.name)) origin=\(input.origin.rawValue)") },
                openStudio: { input in log.append("studio files=\(input.files.count) links=\(input.links.count)") },
                presentLinks: { input, _ in log.append("wheel links=\(input.links.count)") },
                download: { req, origin in log.append("download \(req.link.url.host ?? "") origin=\(origin.rawValue)") },
                toast: { _ in log.append("toast") },
                optionHeld: { option })
            URLRouter.perform(URLRouter.route([file]), origin: .dock, anchor: nil)
            option = true
            URLRouter.perform(URLRouter.route([file]), origin: .dock, anchor: nil)
            option = false
            URLRouter.perform(URLRouter.route([URL(string: "https://example.com/p")!]), origin: .dock, anchor: nil)
            URLRouter.perform(URLRouter.route([URL(string: "swampconverter://download?url=https%3A%2F%2Fexample.com%2Fp")!]), origin: .dock, anchor: nil)
            URLRouter.perform(URLRouter.route([URL(fileURLWithPath: "/definitely/not/here.png")]), origin: .dock, anchor: nil)
            URLRouter.perform(URLRouter.route([URL(string: "swampconverter://download?url=javascript%3Aalert(1)")!]), origin: .dock, anchor: nil)
            URLRouter.perform(.ignored, origin: .dock, anchor: nil)
            try expectEqual(log, ["wheel files=[\"a.png\"] origin=dock", "studio files=1 links=0", "wheel links=1", "download example.com origin=urlScheme", "toast", "toast"])
        }
        t.register("app.router", "a burst of open events is delivered once; nothing stays scheduled afterwards") {
            var delivered: [[URL]] = []
            let b = URLBatcher(quiet: .milliseconds(60), maxWait: .milliseconds(240)) { urls, _, _ in delivered.append(urls) }
            let u = (1...4).map { URL(fileURLWithPath: "/tmp/\($0).png") }
            b.add([u[0]], origin: .dock, anchor: nil)
            try await Task.sleep(for: .milliseconds(20))
            b.add([u[1], u[2]], origin: .dock, anchor: nil)
            try expect(delivered.isEmpty, "still collecting")
            try expect(b.hasPendingWork)
            try await Task.sleep(for: .milliseconds(300))
            try expectEqual(delivered.count, 1); try expectEqual(delivered.first?.count, 3)
            try expect(!b.hasPendingWork, "no timer or task is left at idle")
            b.add([u[3]], origin: .dock, anchor: nil)
            try await Task.sleep(for: .milliseconds(300))
            try expectEqual(delivered.count, 2)
            // A steady trickle is cut off by maxWait instead of waiting forever.
            for _ in 0..<8 { b.add([u[0]], origin: .dock, anchor: nil); try await Task.sleep(for: .milliseconds(40)) }
            try expect(delivered.count >= 3, "maxWait flushes a long stream")
            try await Task.sleep(for: .milliseconds(300))
            try expect(!b.hasPendingWork)
        }
    }

    // MARK: Services

    private static func registerServices(_ t: SelfTestRegistry) {
        t.register("app.services", "Convert: files on the pasteboard open the wheel, an empty selection reports an error string") {
            let (dir, file) = try tempFile()
            defer { AppPaths.removeTemp(dir) }
            let saved = URLRouter.sinks
            defer { URLRouter.sinks = saved }
            var origins: [String] = []
            URLRouter.sinks = URLRouter.Sinks(presentFiles: { input, _ in origins.append("\(input.origin.rawValue):\(input.files.count)") }, openStudio: { _ in }, presentLinks: { _, _ in },
                                              download: { _, _ in }, toast: { _ in }, optionHeld: { false })
            let pb = NSPasteboard(name: NSPasteboard.Name("app.swampconverter.test.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents(); pb.writeObjects([file as NSURL, file as NSURL])
            let provider = ServicesProvider()
            var err: NSString = ""
            provider.convertFiles(pb, userData: "", error: &err)
            try expectEqual(origins, ["service:1"], "duplicates collapse")
            try expectEqual(err as String, "")
            pb.clearContents(); pb.setString("hello", forType: .string)
            provider.convertFiles(pb, userData: "", error: &err)
            try expect((err as String).count > 3, "an error string is returned for the Services error pointer")
        }
        t.register("app.services", "Download: the first valid http(s) link of the selection is used, bad selections explain why") {
            let saved = URLRouter.sinks
            defer { URLRouter.sinks = saved }
            var seen: [[String]] = []
            URLRouter.sinks = URLRouter.Sinks(presentFiles: { _, _ in }, openStudio: { _ in }, presentLinks: { input, _ in seen.append(input.links.map(\.url.absoluteString)) },
                                              download: { _, _ in }, toast: { _ in }, optionHeld: { false })
            let pb = NSPasteboard(name: NSPasteboard.Name("app.swampconverter.test.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            let provider = ServicesProvider()
            var err: NSString = ""
            pb.clearContents(); pb.setString("watch this: https://www.example.com/v?id=7. and file:///etc/passwd", forType: .string)
            provider.downloadLink(pb, userData: "", error: &err)
            try expectEqual(seen, [["https://www.example.com/v?id=7"]]); try expectEqual(err as String, "")
            for bad in ["javascript:alert(1)", "file:///etc/passwd", "just words", "http://localhost:3000/x", ""] {
                pb.clearContents(); pb.setString(bad, forType: .string)
                err = ""
                provider.downloadLink(pb, userData: "", error: &err)
                try expect(!(err as String).isEmpty, "'\(bad)' needs an explanation")
            }
            try expectEqual(seen.count, 1, "nothing was presented for the bad selections")
            // public.url alone
            pb.clearContents(); pb.writeObjects([URL(string: "https://example.org/clip")! as NSURL])
            err = ""
            provider.downloadLink(pb, userData: "", error: &err)
            try expectEqual(seen.last, ["https://example.org/clip"])
        }
        t.register("app.services", "a drop on the status item or Dock reads files first, then web links; other text is refused") {
            let (dir, file) = try tempFile()
            defer { AppPaths.removeTemp(dir) }
            let pb = NSPasteboard(name: NSPasteboard.Name("app.swampconverter.test.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents(); pb.writeObjects([file as NSURL])
            try expectEqual(MenuBarDrop.urls(from: pb).map(\.lastPathComponent), ["a.png"])
            pb.clearContents(); pb.setString("see https://example.com/a and https://example.com/b.", forType: .string)
            try expectEqual(MenuBarDrop.urls(from: pb).map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
            pb.clearContents(); pb.setString("no links here", forType: .string)
            try expect(MenuBarDrop.urls(from: pb).isEmpty)
        }
    }
}
