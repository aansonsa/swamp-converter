import Foundation
import AppKit
import UniformTypeIdentifiers

// Context switching of the hotkey (pure, unit-tested; the one exception is `BrowserKind.probeOther`, which touches Launch Services and is always passed in
// as an injectable closure with that as its default, never called directly from pure code).

enum BrowserKind: Equatable, Hashable, Sendable {
    case safari, safariTechPreview, chrome, chromeCanary, chromium, brave, edge, vivaldi, opera, arc, dia, firefox
    /// Any other browser: one we have no special AppleScript words for, found only because the system itself says it can open web pages (see `probeOther`).
    /// Carries its own bundle ID and display name since there is no fixed case to look them up from.
    case other(bundleID: String, appName: String)

    /// The named browsers (does not include `.other`, which has no fixed identity to enumerate).
    static let allCases: [BrowserKind] = [.safari, .safariTechPreview, .chrome, .chromeCanary, .chromium, .brave, .edge, .vivaldi, .opera, .arc, .dia, .firefox]

    var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .safariTechPreview: return "com.apple.SafariTechnologyPreview"
        case .chrome: return "com.google.Chrome"
        case .chromeCanary: return "com.google.Chrome.canary"
        case .chromium: return "org.chromium.Chromium"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .arc: return "company.thebrowser.Browser"
        case .dia: return "company.thebrowser.dia"
        case .firefox: return "org.mozilla.firefox"
        case .other(let bundleID, _): return bundleID
        }
    }

    /// The name used in `tell application "<name>"`.
    var appleScriptName: String {
        switch self {
        case .safari: return "Safari"
        case .safariTechPreview: return "Safari Technology Preview"
        case .chrome: return "Google Chrome"
        case .chromeCanary: return "Google Chrome Canary"
        case .chromium: return "Chromium"
        case .brave: return "Brave Browser"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .arc: return "Arc"
        case .dia: return "Dia"
        case .firefox: return "Firefox"
        case .other(_, let appName): return appName
        }
    }

    var displayName: String { appleScriptName }

    /// Firefox exposes no URL to AppleScript at all: selected text, then the clipboard, then a clear hint. Dia's own dictionary DOES answer, but — confirmed
    /// live, three different ways (its "active tab", the tab marked `isFocused`, even the window's own name) — for a page reached by client-side navigation
    /// inside an existing tab (opening a video from a YouTube tab that was already showing the homepage, say) it keeps reporting that tab's very first full
    /// page load, not what is actually on screen. There is no reliable way around this short of either Dia's own `execute … javascript` command, which it
    /// refuses unless launched with a flag nobody sets day to day, or reading the real page out through Accessibility, which needs its own separate consent
    /// that (for an ad-hoc, unsigned development build whose code identity changes on every rebuild) macOS does not reliably keep granted — not something to
    /// depend on. A wrong-but-syntactically-valid link is worse than no link: it quietly replaces whatever the person actually meant, so Dia is treated the
    /// same honest way as Firefox rather than risk that. Everything else, including `.other`, is worth trying: a browser we don't recognise by name still
    /// gets the Chromium-style attempt, with a graceful fallback (`BrowserLinkProblem.notUnderstood`) if its own dictionary does not understand the request.
    var exposesTabURL: Bool { self != .firefox && self != .dia }
    /// Safari-family dictionaries use `URL of current tab of front window`; Chromium-family (and `.other`, the best single guess for an unknown browser) use
    /// `URL of active tab of front window`.
    var isSafariFamily: Bool { self == .safari || self == .safariTechPreview }

    /// Named browsers only (does not probe Launch Services): nil for anything else, including a real but unrecognised browser — use `probeOther` for that.
    init?(bundleID: String?) {
        guard let bundleID, let k = BrowserKind.allCases.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return nil }
        self = k
    }

    /// Any OTHER installed application that macOS' own Launch Services treats as a web browser — a browser Swamp Converter has never heard of (Orion, Zen,
    /// Yandex, or one that does not exist yet), detected by behaviour instead of a hardcoded name so new browsers keep working without a code change. Not
    /// one of the named cases above (those are checked first). Touches the real system: always passed in as an injectable, defaultable closure.
    static func probeOther(bundleID: String) -> BrowserKind? {
        guard BrowserKind(bundleID: bundleID) == nil,
              let appURL = webBrowserApps().first(where: { Bundle(url: $0)?.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return nil }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? displayName(ofAppAt: appURL) ?? bundleID
        return .other(bundleID: bundleID, appName: name)
    }

    /// Every other browser Launch Services knows about and that is not one of the named cases — used to offer "Allow Access…" consent for all of them,
    /// not just the ones running right now.
    static func installedOtherBrowsers() -> [BrowserKind] {
        let known = Set(allCases.map { $0.bundleID.lowercased() })
        var seen = Set<String>()
        var out: [BrowserKind] = []
        for appURL in webBrowserApps() {
            guard let id = Bundle(url: appURL)?.bundleIdentifier, !known.contains(id.lowercased()), seen.insert(id.lowercased()).inserted else { continue }
            out.append(.other(bundleID: id, appName: displayName(ofAppAt: appURL) ?? id))
        }
        return out
    }

    /// Apps that open both an https link AND an HTML file — the same pair macOS itself uses to decide who may be the default web browser. Opening https
    /// alone is not enough: apps register it for their own deep links too (ChatGPT.app does, on the owner's Mac), and treating one of those as a browser
    /// would greet the person with "Read the page address from ChatGPT?" and an Automation prompt for an app that has no pages.
    private static func webBrowserApps() -> [URL] {
        guard let exampleURL = URL(string: "https://example.com") else { return [] }
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: UTType.html).map(\.standardizedFileURL))
        return NSWorkspace.shared.urlsForApplications(toOpen: exampleURL).filter { html.contains($0.standardizedFileURL) }
    }

    private static func displayName(ofAppAt url: URL) -> String? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
    }
}

enum WheelContext {
    enum Decision: Equatable, Sendable {
        /// Try the link first, then fall back to the files.
        case linkFirst(BrowserKind)
        case filesFirst
    }

    /// Frontmost app is a known browser -> link first (even when Finder items are selected); a real but unrecognised browser (`genericBrowser`) the same way;
    /// Finder or any other app -> files first.
    static func decide(frontmostBundleID: String?, genericBrowser: (String) -> BrowserKind? = BrowserKind.probeOther) -> Decision {
        if let known = BrowserKind(bundleID: frontmostBundleID) { return .linkFirst(known) }
        if let id = frontmostBundleID, let other = genericBrowser(id) { return .linkFirst(other) }
        return .filesFirst
    }
}

/// The order in which the hotkey looks for something to act on (pure, unit-tested). The browser is asked ONLY when it is the front app; Finder ONLY when Finder is: asking
/// Finder for its selection while another app is in front would hand over files the person is not looking at. The clipboard is always the last resort.
enum WheelHotkeyPlan {
    enum Step: Equatable, Sendable {
        case browserLink(BrowserKind)
        case finderSelection
        case clipboard
    }

    static func steps(frontmostBundleID: String?, hotkeyReadsBrowser: Bool, usesFinderSelection: Bool,
                       genericBrowser: (String) -> BrowserKind? = BrowserKind.probeOther) -> [Step] {
        var steps: [Step] = []
        switch WheelContext.decide(frontmostBundleID: frontmostBundleID, genericBrowser: genericBrowser) {
        case .linkFirst(let browser):
            if hotkeyReadsBrowser { steps.append(.browserLink(browser)) }
        case .filesFirst:
            if usesFinderSelection, frontmostBundleID == FinderSelectionReader.finderBundleID { steps.append(.finderSelection) }
        }
        steps.append(.clipboard)
        return steps
    }
}
