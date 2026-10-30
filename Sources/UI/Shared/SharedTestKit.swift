import SwiftUI
import AppKit

/// Helpers for the shared self-tests: measuring SwiftUI views without a screen, locating the source tree for the lint tests.
@MainActor
enum SharedTestKit {
    /// The size a SwiftUI view asks for when it is offered `width` and unlimited height (the height shows whether text wrapped or was cut).
    static func fitting<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).appRoot())
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        return host.fittingSize
    }

    /// The height `text` needs in `font` at `width` (an independent measurement, by TextKit).
    static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return ceil(rect.height)
    }

    /// An on-screen-never window that gives a view a `window` (for `viewDidMoveToWindow` behaviour).
    static func offscreenWindow(containing view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        w.contentView?.addSubview(view)
        return w
    }

    /// CPU seconds (user + system) this process has used so far; differences of two readings measure a stretch of work.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The first view of `type` below `root` (depth first). SwiftUI controls are AppKit views, so this tells what was really built.
    static func firstDescendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        for v in root.subviews {
            if let match = v as? T { return match }
            if let deeper = firstDescendant(of: v, as: type) { return deeper }
        }
        return nil
    }

    /// `Sources/` of the project this binary was built from (nil when the source tree is not where it was at build time).
    static func sourcesRoot(from file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<8 {
            if url.lastPathComponent == "Sources" { return FileManager.default.fileExists(atPath: url.path) ? url : nil }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// All `.swift` files under `dir` (no `._*` sidecars), with their text.
    static func swiftSources(in dir: URL) -> [(path: String, text: String)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let u as URL in e where u.pathExtension == "swift" && !u.lastPathComponent.hasPrefix("._") {
            if let t = try? String(contentsOf: u, encoding: .utf8) { out.append((u.path, t)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
