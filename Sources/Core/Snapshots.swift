import SwiftUI
import AppKit

// Offscreen snapshots: `SwampConverter --snapshot <dir> [filter]` (or `./build.sh snapshot <dir>`).
//
// Why this is not ImageRenderer: Liquid Glass, materials and vibrancy only render when WindowServer composites a real
// window. The harness puts the view, a realistic sample backdrop and the glass in ONE borderless panel placed far
// outside every display (it never touches the desktop), waits until the pixels stop changing, captures that single
// window with CGWindowListCreateImage (loaded with dlsym, needs no permission) and writes a PNG.
//
//   SnapshotRegistry.shared.register("shared.glass-panel", size: CGSize(width: 360, height: 220)) {
//       GlassPanel { Text("Hello") }
//   }
//
// ACTIVE LOOK. A command-line process can never become the active application on macOS 26 (verified with NSApp.activate(), activate(ignoringOtherApps:),
// NSRunningApplication.activate, finishLaunching + a real NSApplication.run loop, a LaunchServices launch with and without -g, a regular activation policy,
// a titled non-activating NSPanel, and an on-screen window), so AppKit draws every system control (switch, slider, segmented control, progress bar,
// traffic lights) in its inactive grey. The windows below therefore answer the two undocumented questions AppKit asks to choose that look
// (`_hasActiveControls`, `hasKeyAppearance`) with "yes" and report themselves as key and main; nothing is activated, no focus is taken from the person
// using the Mac, and nothing is shown. If AppKit stops asking, nothing breaks: the controls just draw grey again.
// `SWAMP_SNAPSHOT_REAL_STATE=1` captures the real (inactive) state instead; `SWAMP_SNAPSHOT_ACTIVATE=1` additionally tries to activate the app (it steals focus and
// has not been seen to work).
//
// Every registration is rendered for each variant (default: light + dark). Files are named
// `<name>.<variant>.png`, e.g. `shared.glass-panel.dark.ru.png`. Variants can force Russian, Reduce Transparency,
// Reduce Motion and Increase Contrast (they set `\.a11yOverride`, which `.appRoot()` honours).

struct SnapshotVariant: Hashable, Sendable {
    var dark = false
    var language: AppLanguage = .en
    var reduceTransparency = false
    var reduceMotion = false
    var increaseContrast = false

    var a11y: A11y { A11y(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, increaseContrast: increaseContrast, differentiateWithoutColor: false) }

    /// "light", "dark.ru", "light.rt.ic" ...
    var suffix: String {
        var s = dark ? "dark" : "light"
        if language == .ru { s += ".ru" }
        if reduceTransparency { s += ".rt" }
        if reduceMotion { s += ".rm" }
        if increaseContrast { s += ".ic" }
        return s
    }

    static let light = SnapshotVariant()
    static let dark = SnapshotVariant(dark: true)
    static let lightDark = [light, dark]
    static let lightDarkRu = [light, dark, SnapshotVariant(dark: false, language: .ru), SnapshotVariant(dark: true, language: .ru)]
    /// The accessibility matrix for custom-drawn controls (wheel, progress bars, chips).
    static let accessibility = [SnapshotVariant(reduceTransparency: true), SnapshotVariant(dark: true, reduceTransparency: true),
                                SnapshotVariant(increaseContrast: true), SnapshotVariant(dark: true, increaseContrast: true),
                                SnapshotVariant(reduceMotion: true)]
}

enum SnapshotBackdrop: Sendable {
    /// Nothing behind the view (window / sheet content that has its own background).
    case none
    /// A colourful, photo-like desktop picture with a Finder-like window: what glass floats over in real life.
    case wallpaper
    /// The system window background (settings pages, Studio).
    case windowBackground
}

enum SnapshotChrome: Sendable {
    /// Borderless transparent panel: overlays, wheels, HUD cards, popovers.
    case none
    /// A real titled window (traffic lights, title bar): Settings, Studio, About.
    case window(title: String)
}

struct SnapshotSpec {
    var name: String
    var size: CGSize
    var backdrop: SnapshotBackdrop
    var chrome: SnapshotChrome
    var variants: [SnapshotVariant]
    var content: @MainActor () -> AnyView
}

final class SnapshotRegistry: @unchecked Sendable {
    static let shared = SnapshotRegistry()
    private let lock = NSLock()
    private var _specs: [SnapshotSpec] = []
    var specs: [SnapshotSpec] { lock.lock(); defer { lock.unlock() }; return _specs }

    /// `name` is "<module>.<what>" ("wheel.six-sectors", "settings.general"). Re-registering a name replaces it.
    func register<V: View>(_ name: String, size: CGSize, backdrop: SnapshotBackdrop = .wallpaper, chrome: SnapshotChrome = .none,
                           variants: [SnapshotVariant] = SnapshotVariant.lightDark, @ViewBuilder _ content: @escaping @MainActor () -> V) {
        let spec = SnapshotSpec(name: name, size: size, backdrop: backdrop, chrome: chrome, variants: variants, content: { AnyView(content()) })
        lock.lock(); _specs.removeAll { $0.name == name }; _specs.append(spec); lock.unlock()
    }

    func selected(filter: String?) -> [SnapshotSpec] {
        guard let f = filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return specs }
        return specs.filter { $0.name.range(of: f, options: .caseInsensitive) != nil }
    }
}

// MARK: - Backdrops

/// A neutral, photo-like wallpaper with soft colour fields and a mock Finder window, so glass has something to refract.
struct SnapshotWallpaper: View {
    var dark: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: dark ? [Color(red: 0.07, green: 0.10, blue: 0.20), Color(red: 0.22, green: 0.13, blue: 0.30)]
                                            : [Color(red: 0.55, green: 0.72, blue: 0.86), Color(red: 0.93, green: 0.78, blue: 0.70)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(dark ? Color(red: 0.55, green: 0.25, blue: 0.45).opacity(0.55) : Color(red: 1.0, green: 0.78, blue: 0.55).opacity(0.8))
                    .frame(width: w * 0.7).offset(x: w * 0.25, y: -h * 0.25).blur(radius: 40)
                Circle().fill(dark ? Color(red: 0.12, green: 0.40, blue: 0.55).opacity(0.6) : Color(red: 0.45, green: 0.80, blue: 0.80).opacity(0.7))
                    .frame(width: w * 0.6).offset(x: -w * 0.3, y: h * 0.3).blur(radius: 50)
                mockWindow(w: w, h: h)
            }
        }
    }

    private func mockWindow(w: CGFloat, h: CGFloat) -> some View {
        let panel = dark ? Color(white: 0.16) : Color(white: 0.97)
        let tile = dark ? Color(white: 0.28) : Color(white: 0.84)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(panel)
            HStack(spacing: 0) {
                Rectangle().fill(tile.opacity(0.5)).frame(width: w * 0.22)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<4, id: \.self) { r in
                        HStack(spacing: 10) {
                            ForEach(0..<5, id: \.self) { c in
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tile).frame(width: 34, height: 34)
                                    RoundedRectangle(cornerRadius: 2).fill(tile.opacity(0.8)).frame(width: 28, height: 4)
                                }
                                .opacity(Double((r * 5 + c) % 3 == 0 ? 1 : 0.85))
                            }
                        }
                    }
                }.padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: w * 0.9, height: h * 0.8)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }
}

// MARK: - Renderer

/// Whether the snapshot windows pretend to be the active window (see the header). On by default.
private let snapshotForcesActiveLook = ProcessInfo.processInfo.environment["SWAMP_SNAPSHOT_REAL_STATE"] != "1"

private final class SnapPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { snapshotForcesActiveLook || super.isKeyWindow }
    override var isMainWindow: Bool { snapshotForcesActiveLook || super.isMainWindow }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
    @objc func _hasActiveControls() -> Bool { true }
    @objc var hasKeyAppearance: Bool { true }
}
private final class SnapWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { snapshotForcesActiveLook || super.isKeyWindow }
    override var isMainWindow: Bool { snapshotForcesActiveLook || super.isMainWindow }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
    @objc func _hasActiveControls() -> Bool { true }
    @objc var hasKeyAppearance: Bool { true }
}

enum SnapshotError: Error, CustomStringConvertible {
    case noCaptureFunction, captureFailed
    var description: String {
        switch self {
        case .noCaptureFunction: return "CGWindowListCreateImage is not available"
        case .captureFailed: return "the window server returned no image (is there a GUI session?)"
        }
    }
}

@MainActor
enum SnapshotRenderer {
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Renders every selected snapshot into `dir`; returns the written files and the failures.
    static func renderAll(to dir: URL, filter: String?) async -> (written: [URL], failures: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [URL] = [], failures: [String] = [], index: [String] = []
        let specs = SnapshotRegistry.shared.selected(filter: filter)
        if specs.isEmpty { return ([], ["no snapshots match \(filter.map { "'\($0)'" } ?? "(none registered)")"]) }
        for spec in specs {
            for variant in spec.variants {
                let file = dir.appendingPathComponent("\(spec.name).\(variant.suffix).png")
                do {
                    let image = try await render(spec, variant: variant)
                    try writePNG(image, to: file)
                    written.append(file)
                    index.append("\(file.lastPathComponent)\t\(image.width)x\(image.height)")
                    out("  ok  \(file.lastPathComponent)")
                } catch {
                    failures.append("\(spec.name).\(variant.suffix): \(error)")
                    out("FAIL  \(spec.name).\(variant.suffix): \(error)")
                }
            }
        }
        try? index.joined(separator: "\n").write(to: dir.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
        return (written, failures)
    }

    static func render(_ spec: SnapshotSpec, variant: SnapshotVariant) async throws -> CGImage {
        Loc.shared.set(variant.language == .ru ? .russian : .english)
        let appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let backdropView: AnyView
        switch spec.backdrop {
        case .none: backdropView = AnyView(Color.clear)
        case .wallpaper: backdropView = AnyView(SnapshotWallpaper(dark: variant.dark))
        case .windowBackground: backdropView = AnyView(Color(nsColor: .windowBackgroundColor))
        }
        let root = ZStack {
            backdropView
            spec.content().frame(width: spec.size.width, height: spec.size.height)
        }
        .frame(width: spec.size.width, height: spec.size.height)
        .environment(\.a11yOverride, variant.a11y)
        .environment(\.controlActiveState, .key)
        .localizedRoot()

        let hosting = NSHostingView(rootView: root)
        let frame = NSRect(x: -4000, y: -4000, width: spec.size.width, height: spec.size.height)
        let window: NSWindow
        switch spec.chrome {
        case .none:
            let p = SnapPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            window = p
        case .window(let title):
            let w = SnapWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = title
            window = w
        }
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrame(window.frameRect(forContentRect: frame), display: false)   // AFTER init: init-time frames are clamped onto a screen
        window.orderFrontRegardless()
        // Controls draw their ACTIVE look (tint, glass) only for the active window: the snapshot windows claim to be it (see the header). The window is far off every display.
        if ProcessInfo.processInfo.environment["SWAMP_SNAPSHOT_ACTIVATE"] == "1" { NSApp.activate(ignoringOtherApps: true) }
        window.makeKey()
        defer { window.orderOut(nil); window.close() }

        // Wait until two consecutive captures are identical (glass and materials need a few run-loop turns to settle).
        var previous: Data?
        var latest: CGImage?
        try await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<10 {
            guard let img = try capture(window) else { throw SnapshotError.captureFailed }
            latest = img
            let data = img.dataProvider?.data as Data?
            if let p = previous, let d = data, p == d { return img }
            previous = data
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        guard let latest else { throw SnapshotError.captureFailed }
        return latest
    }

    private static func capture(_ window: NSWindow) throws -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { throw SnapshotError.noCaptureFunction }
        let fn = unsafeBitCast(sym, to: CaptureFn.self)
        // kCGWindowListOptionIncludingWindow = 8; kCGWindowImageBoundsIgnoreFraming = 1 | kCGWindowImageBestResolution = 8
        return fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw SnapshotError.captureFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.captureFailed }
    }
}
