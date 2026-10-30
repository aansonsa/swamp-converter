import Foundation
import AppKit
import UniformTypeIdentifiers

// The text side of the one-keystroke features: AppleScript goldens per browser (compile-checked for the apps every Mac has, never executed), parsers, link extraction from selected
// text, the order of the reader chain with stubbed system calls, and the hotkey plan and resolver.

extension WheelTests {
    static let safariGolden = """
    with timeout of 1 seconds
    tell application "Safari"
    if (count of windows) is 0 then return "__swamp_no_window__"
    set theURL to ""
    set theTitle to ""
    try
    set theURL to URL of current tab of front window
    end try
    try
    set theTitle to name of current tab of front window
    end try
    if theURL is missing value then set theURL to ""
    if theTitle is missing value then set theTitle to ""
    return theURL & linefeed & theTitle
    end tell
    end timeout
    """

    static let chromeGolden = """
    with timeout of 1 seconds
    tell application "Google Chrome"
    if (count of windows) is 0 then return "__swamp_no_window__"
    set theURL to ""
    set theTitle to ""
    try
    set theURL to URL of active tab of front window
    end try
    try
    set theTitle to title of active tab of front window
    end try
    if theURL is missing value then set theURL to ""
    if theTitle is missing value then set theTitle to ""
    return theURL & linefeed & theTitle
    end tell
    end timeout
    """

    static let finderGolden = """
    with timeout of 1 seconds
    tell application "Finder"
    set theSelection to selection as alias list
    set theResult to ""
    repeat with oneItem in theSelection
    set theResult to theResult & POSIX path of oneItem & linefeed
    end repeat
    return theResult
    end tell
    end timeout
    """

    /// A reader whose every system call is replaced.
    @MainActor
    static func stubReader(selected: String? = nil, clipboard: String? = nil, automation: BrowserLinkReader.Automation = .granted, explained: Bool = true,
                           script: AppleScriptOutcome = .text("https://example.com/watch?v=1\nExample page"), consent: AppleScriptRunner.Consent = .granted,
                           genericBrowser: @escaping (String) -> BrowserKind? = { _ in nil }, ran: Box<[String]> = Box([])) -> BrowserLinkReader {
        let r = BrowserLinkReader()
        r.environment = BrowserLinkReader.Environment(
            selectedText: { selected }, clipboardText: { clipboard }, automation: { _ in automation }, isExplained: { _ in explained },
            runScript: { source, _ in ran.value.append(source); return script }, askConsent: { _ in consent }, genericBrowser: genericBrowser)
        return r
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    static func registerBrowser() {
        let t = SelfTestRegistry.shared
        t.register("wheel", "AppleScript goldens: Safari, Chrome and Finder scripts are exact; every other browser uses its own words and escaped names; Firefox and Dia have none") {
            try expectEqual(BrowserScripts.activeTabScript(for: .safari), safariGolden)
            try expectEqual(BrowserScripts.activeTabScript(for: .chrome), chromeGolden)
            try expectEqual(BrowserScripts.finderSelectionScript(), finderGolden)
            for kind in BrowserKind.allCases {
                guard let script = BrowserScripts.activeTabScript(for: kind) else {
                    try expect(kind == .firefox || kind == .dia, "only Firefox (no address at all) and Dia (its own address is unreliable) have no script")
                    continue
                }
                try expect(script.contains("tell application \"\(kind.appleScriptName)\""), "\(kind) names its application")
                try expect(script.hasPrefix("with timeout of 1 seconds") && script.hasSuffix("end timeout"), "\(kind) has a time limit")
                try expect(script.contains(BrowserScripts.noWindowMarker), "\(kind) reports a missing window")
                let words = kind.isSafariFamily ? "URL of current tab of front window" : "URL of active tab of front window"
                try expect(script.contains(words), "\(kind) uses the right dictionary words")
                try expect(kind == .arc || !script.contains(kind.isSafariFamily ? "active tab" : "current tab"), "\(kind) does not mix the dictionaries")
            }
            try expect(BrowserScripts.activeTabScript(for: .arc)?.contains("current tab of front window") == true, "Arc falls back to the Safari words")
            try expectEqual(BrowserScripts.escape("A \"quoted\" \\ name\nnext"), "A \\\"quoted\\\" \\\\ name next")
            try expect(!BrowserKind.allCases.contains { BrowserScripts.activeTabScript(for: $0)?.contains("\\\"") == true }, "no application name needs escaping")
        }
        t.register("wheel", "AppleScript: the scripts of the apps every Mac has compile (compile only: no Apple event is sent, no consent dialog)") {
            for source in [BrowserScripts.activeTabScript(for: .safari)!, BrowserScripts.finderSelectionScript()] {
                if let error = AppleScriptRunner.compileError(source) { throw TestFailure(message: "does not compile: \(error)", file: #fileID, line: #line) }
            }
        }
        t.register("wheel", "AppleScriptRunner really runs a script (unstubbed): text comes back, and a script that never finishes is killed well before its own timeout") {
            let fast = await AppleScriptRunner.run("return \"hello\"", timeout: 2)
            try expectEqual(fast, .text("hello"))
            let t0 = Date()
            // `delay` pauses the script itself (no Apple event sent anywhere, no app needed): a dependable stand-in for a target that never answers.
            let slow = await AppleScriptRunner.run("delay 6\nreturn \"too slow\"", timeout: 0.5)
            let elapsed = Date().timeIntervalSince(t0)
            try expectEqual(slow, .timedOut)
            try expect(elapsed < 3, "killed near its own 0.5 s timeout (\(elapsed) s), not left to run the full 6 s delay — this is the exact failure that once froze the wheel hotkey for the rest of the session")
        }
        t.register("wheel", "script results: parse the tab text, the Finder paths and the markers") {
            let ok = BrowserScripts.parseResult("https://example.com/a?b=1\nA title with: colons")
            try expectEqual(ok?.url.absoluteString, "https://example.com/a?b=1"); try expectEqual(ok?.title, "A title with: colons")
            try expectEqual(BrowserScripts.parseResult("https://example.com/\r\nWindows line")?.title, "Windows line")
            try expectEqual(BrowserScripts.parseResult("https://example.com/\n")?.title, nil)
            try expectEqual(BrowserScripts.parseResult("https://example.com/\nmissing value")?.title, nil)
            try expect(BrowserScripts.parseResult("") == nil && BrowserScripts.parseResult("missing value") == nil && BrowserScripts.parseResult("\n") == nil)
            try expect(BrowserScripts.parseResult("__swamp_no_window__") == nil && BrowserScripts.parseResult("not a url") == nil)
            try expect(BrowserScripts.isNoWindow("__swamp_no_window__\n") && !BrowserScripts.isNoWindow("https://a.com"))
            let paths = BrowserScripts.parseFinderSelection("/Users/me/a.png\n/Users/me/b b.jpg\r/Users/me/a.png\nrelative.txt\n\n/\n")
            try expectEqual(paths.map(\.path), ["/Users/me/a.png", "/Users/me/b b.jpg"], "absolute, unique, in order")
        }
        t.register("wheel", "links in selected text: punctuation, several links, youtu.be, tracking noise; javascript:, file: and private hosts are refused") {
            let text = "Watch (https://www.youtube.com/watch?v=abc123&utm_source=x), then https://youtu.be/abc123. Also see https://vimeo.com/12345!"
            let links = LinkParsing.downloadableLinks(in: text)
            try expectEqual(links.count, 2, "youtu.be and the watch link are the same video")
            try expectEqual(links.first?.url.host, "www.youtube.com")
            try expect(!(links.first?.url.absoluteString.contains("utm_source") ?? true), "tracking removed")
            try expectEqual(links.last?.url.absoluteString, "https://vimeo.com/12345")
            try expectEqual(LinkParsing.downloadableLinks(in: "www.example.com/page").first?.url.absoluteString, "https://www.example.com/page")
            for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/a", "http://localhost:8080/x", "http://192.168.1.2/a", "https://user:pw@example.com/"] {
                try expect(LinkParsing.downloadableLinks(in: bad).isEmpty, "\(bad) must not be offered")
                if case .success = LinkParsing.validate(bad) { throw TestFailure(message: "\(bad) validated", file: #fileID, line: #line) }
            }
            try expectEqual(LinkParsing.schemeRejection(forText: "javascript:alert(1)"), .unsupportedScheme("javascript"))
        }
        t.register("wheel", "browser reader: selected text beats the tab, the tab beats the clipboard, and nothing is asked before it must be") {
            let ran = Box<[String]>([])
            let a = stubReader(selected: "see https://selected.example.com/video here", clipboard: "https://clip.example.com/x", ran: ran)
            let r1 = await a.readCurrent(frontmostBundleID: BrowserKind.safari.bundleID)
            try expectEqual(r1.source, .selection); try expectEqual(r1.link?.url.host, "selected.example.com"); try expect(ran.value.isEmpty, "no script ran")
            let b = stubReader(clipboard: "https://clip.example.com/x", ran: ran)
            let r2 = await b.readCurrent(frontmostBundleID: BrowserKind.chrome.bundleID)
            try expectEqual(r2.source, .activeTab); try expectEqual(r2.link?.url.host, "example.com"); try expectEqual(r2.pageTitle, "Example page")
            try expectEqual(ran.value.count, 1); try expect(ran.value[0].contains("Google Chrome"), "the Chrome script ran")
            let c = stubReader(clipboard: "https://clip.example.com/x", script: .failure(number: AppleScriptOutcome.appleEventTimedOut, message: ""))
            let r3 = await c.readCurrent(frontmostBundleID: BrowserKind.safari.bundleID)
            try expectEqual(r3.source, .clipboard, "a slow browser falls back to the clipboard"); try expectEqual(r3.problem, .timedOut(.safari))
            let d = stubReader(script: .text("__swamp_no_window__"))
            let r4 = await d.readCurrent(frontmostBundleID: BrowserKind.brave.bundleID)
            try expectEqual(r4.link?.url, nil); try expectEqual(r4.problem, .noWindow(.brave))
            let e = stubReader(script: .text("chrome://settings\nSettings"))
            let r5 = await e.readCurrent(frontmostBundleID: BrowserKind.chrome.bundleID)
            if case .notDownloadable? = r5.problem {} else { throw TestFailure(message: "chrome:// must be refused, got \(String(describing: r5.problem))", file: #fileID, line: #line) }
        }
        t.register("wheel", "browser reader: the explanation comes before the system prompt, a refusal is remembered, Firefox needs a selection or the clipboard") {
            let ran = Box<[String]>([])
            let first = stubReader(automation: .notDetermined, explained: false, ran: ran)
            let r1 = await first.readCurrent(frontmostBundleID: BrowserKind.safari.bundleID)
            try expectEqual(r1.problem, .needsAutomationExplanation(.safari)); try expect(ran.value.isEmpty, "nothing ran, no system dialog")
            let explained = stubReader(automation: .notDetermined, explained: true, consent: .granted, ran: ran)
            let r2 = await explained.readCurrent(frontmostBundleID: BrowserKind.safari.bundleID)
            try expectEqual(r2.source, .activeTab, "after the explanation the consent is asked and the script runs")
            let refused = stubReader(automation: .notDetermined, explained: true, consent: .denied)
            let rRefused = await refused.readCurrent(frontmostBundleID: BrowserKind.safari.bundleID)
            try expectEqual(rRefused.problem, .automationDenied(.safari))
            let denied = stubReader(automation: .denied)
            let rDenied = await denied.readCurrent(frontmostBundleID: BrowserKind.edge.bundleID)
            try expectEqual(rDenied.problem, .automationDenied(.edge))
            let deniedWithClip = stubReader(clipboard: "https://old.example.com/clip", automation: .denied)
            let rDeniedClip = await deniedWithClip.readCurrent(frontmostBundleID: BrowserKind.chrome.bundleID)
            try expect(rDeniedClip.link == nil, "a refused browser is reported, not replaced by an old address on the clipboard")
            try expectEqual(rDeniedClip.problem, .automationDenied(.chrome))
            let off = stubReader(automation: .browserNotRunning)
            let rOff = await off.readCurrent(frontmostBundleID: BrowserKind.vivaldi.bundleID)
            try expectEqual(rOff.problem, .noWindow(.vivaldi))
            let fx = stubReader(clipboard: nil)
            let rFx = await fx.readCurrent(frontmostBundleID: BrowserKind.firefox.bundleID)
            try expectEqual(rFx.problem, .noReliableTabURL(.firefox))
            let fxClip = stubReader(clipboard: "https://example.org/v")
            let r3 = await fxClip.readCurrent(frontmostBundleID: BrowserKind.firefox.bundleID)
            try expectEqual(r3.source, .clipboard); try expectEqual(r3.problem, .noReliableTabURL(.firefox))
            let none = stubReader()
            let r4 = await none.readCurrent(frontmostBundleID: "com.apple.finder")
            try expectEqual(r4.problem, .noLinkFound, "outside a browser, with nothing selected and nothing copied")
            for p in [BrowserLinkProblem.automationDenied(.chrome), .noWindow(.arc), .timedOut(.opera), .noReliableTabURL(.firefox), .noLinkFound, .needsAutomationExplanation(.brave)] {
                try expect(!p.message.en.isEmpty && !p.message.ru.isEmpty && p.message.en != p.message.ru, "\(p) is written in both languages")
            }
        }
        t.register("wheel", "hotkey plan: the browser is read only when it is in front, Finder only when it is, the clipboard always last; the settings can switch them off") {
            let safari = BrowserKind.safari.bundleID
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: safari, hotkeyReadsBrowser: true, usesFinderSelection: true), [.browserLink(.safari), .clipboard])
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: safari, hotkeyReadsBrowser: false, usesFinderSelection: true), [.clipboard])
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: "com.apple.finder", hotkeyReadsBrowser: true, usesFinderSelection: true), [.finderSelection, .clipboard])
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: "com.apple.finder", hotkeyReadsBrowser: true, usesFinderSelection: false), [.clipboard])
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: "com.apple.mail", hotkeyReadsBrowser: true, usesFinderSelection: true), [.clipboard], "Finder's selection is not read while Mail is in front")
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: nil, hotkeyReadsBrowser: true, usesFinderSelection: true), [.clipboard])
        }
        t.register("wheel", "Dia is a named browser like any other; a real browser we have no name for still gets link-first treatment through probeOther") {
            try expectEqual(BrowserKind(bundleID: "company.thebrowser.dia"), .dia)
            try expectEqual(BrowserKind(bundleID: "COMPANY.THEBROWSER.DIA"), .dia, "case-insensitive, like every other lookup")
            // Dia's own AppleScript answer is confirmed unreliable for client-side (SPA) navigation inside an existing tab, so — like Firefox — it is not
            // trusted at all: selection, then the clipboard, with an honest "copy the address" hint, never a silently wrong link.
            try expect(!BrowserKind.dia.exposesTabURL && !BrowserKind.dia.isSafariFamily, "Dia is not trusted for its own tab URL")
            // probeOther never touches the system for a bundle ID that is already one of the named cases, or for a bundle ID that plainly has nothing to
            // do with a browser: both are deterministic regardless of what is installed on the machine running the test.
            try expectEqual(BrowserKind.probeOther(bundleID: BrowserKind.safari.bundleID), nil, "Safari already has a name; probeOther defers to it")
            try expectEqual(BrowserKind.probeOther(bundleID: "app.swampconverter.definitely-not-a-browser"), nil)
            let other = BrowserKind.other(bundleID: "com.example.mystery", appName: "Mystery Browser")
            try expectEqual(WheelContext.decide(frontmostBundleID: "com.example.mystery", genericBrowser: { _ in other }), .linkFirst(other))
            try expectEqual(WheelContext.decide(frontmostBundleID: "com.example.notabrowser", genericBrowser: { _ in nil }), .filesFirst)
            try expectEqual(WheelHotkeyPlan.steps(frontmostBundleID: "com.example.mystery", hotkeyReadsBrowser: true, usesFinderSelection: true, genericBrowser: { _ in other }),
                            [.browserLink(other), .clipboard], "an unrecognised-but-real browser is read first, same as a named one")
            try expect(BrowserScripts.activeTabScript(for: other)?.contains("tell application \"Mystery Browser\"") == true, "the generic case still gets a Chromium-style script, by its own name")
        }
        t.register("wheel", "browser reader: an unrecognised-but-real browser is tried like Chrome; if its own dictionary refuses the verb, the hint is to copy the address") {
            let other = BrowserKind.other(bundleID: "com.example.mystery", appName: "Mystery Browser")
            let ran = Box<[String]>([])
            let found = stubReader(genericBrowser: { _ in other }, ran: ran)
            let r1 = await found.readCurrent(frontmostBundleID: "com.example.mystery")
            try expectEqual(r1.source, .activeTab); try expect(ran.value.first?.contains("Mystery Browser") == true)
            let refuses = stubReader(clipboard: "https://clip.example.com/x", script: .failure(number: AppleScriptOutcome.eventNotHandled, message: ""), genericBrowser: { _ in other })
            let r2 = await refuses.readCurrent(frontmostBundleID: "com.example.mystery")
            try expectEqual(r2.source, .clipboard); try expectEqual(r2.problem, .notUnderstood(other))
            try expect(!BrowserLinkProblem.notUnderstood(.dia).message.en.isEmpty && !BrowserLinkProblem.notUnderstood(.dia).message.ru.isEmpty &&
                       BrowserLinkProblem.notUnderstood(.dia).message.en != BrowserLinkProblem.notUnderstood(.dia).message.ru)
            let notABrowser = stubReader(genericBrowser: { _ in nil })
            let r3 = await notABrowser.readCurrent(frontmostBundleID: "com.example.notabrowser")
            try expectEqual(r3.problem, .noLinkFound, "nothing pretends to be a browser just because it is unrecognised")
        }
        t.register("wheel", "hotkey resolver: link, Finder files, clipboard image, permission steps and the calm message, each from stubbed readers") {
            let fx = TestFixtures(label: "wheel-hotkey")
            defer { fx.cleanup() }
            let png = FileItem(url: try fx.png("shot.png"))
            let link = LinkItem(url: URL(string: "https://example.com/v")!, title: "T")
            var resolver = WheelHotkeyResolver()
            resolver.browser = { _ in BrowserLinkResult(link: link, pageTitle: "Page", source: .activeTab, problem: nil) }
            resolver.finder = { .files([png]) }
            resolver.clipboard = { .empty }
            let settings = SettingsData()
            if case .link(let l, let title) = await resolver.resolve(frontmostBundleID: BrowserKind.safari.bundleID, settings: settings) { try expectEqual(l, link); try expectEqual(title, "Page") } else { throw TestFailure(message: "expected the link", file: #fileID, line: #line) }
            if case .files(let items) = await resolver.resolve(frontmostBundleID: "com.apple.finder", settings: settings) { try expectEqual(items.count, 1) } else { throw TestFailure(message: "expected Finder files", file: #fileID, line: #line) }
            resolver.finder = { .needsExplanation }
            if case .needsPermission(.explainFinder) = await resolver.resolve(frontmostBundleID: "com.apple.finder", settings: settings) {} else { throw TestFailure(message: "expected the Finder explanation", file: #fileID, line: #line) }
            resolver.finder = { .denied }
            if case .needsPermission(.deniedFinder) = await resolver.resolve(frontmostBundleID: "com.apple.finder", settings: settings) {} else { throw TestFailure(message: "expected the Finder recovery", file: #fileID, line: #line) }
            resolver.clipboard = { .files([png]) }
            if case .files = await resolver.resolve(frontmostBundleID: "com.apple.finder", settings: settings) {} else { throw TestFailure(message: "the clipboard files beat a refusal", file: #fileID, line: #line) }
            resolver.clipboard = { .image(png) }
            if case .clipboardImage = await resolver.resolve(frontmostBundleID: "com.apple.mail", settings: settings) {} else { throw TestFailure(message: "expected the clipboard image", file: #fileID, line: #line) }
            var noImages = settings
            noImages.offerClipboardImage = false
            if case .message = await resolver.resolve(frontmostBundleID: "com.apple.mail", settings: noImages) {} else { throw TestFailure(message: "the image is not offered when the setting is off", file: #fileID, line: #line) }
            resolver.clipboard = { .links([link]) }
            if case .clipboardLinks(let l) = await resolver.resolve(frontmostBundleID: nil, settings: settings) { try expectEqual(l.count, 1) } else { throw TestFailure(message: "expected clipboard links", file: #fileID, line: #line) }
            resolver.clipboard = { .empty }
            resolver.browser = { _ in BrowserLinkResult(link: nil, pageTitle: nil, source: nil, problem: .needsAutomationExplanation(.chrome)) }
            if case .needsPermission(.explainBrowser(.chrome)) = await resolver.resolve(frontmostBundleID: BrowserKind.chrome.bundleID, settings: settings) {} else { throw TestFailure(message: "expected the browser explanation", file: #fileID, line: #line) }
            resolver.browser = { _ in BrowserLinkResult(link: nil, pageTitle: nil, source: nil, problem: .noWindow(.chrome)) }
            if case .message(let m) = await resolver.resolve(frontmostBundleID: BrowserKind.chrome.bundleID, settings: settings) { try expect(m.en.contains("no open window")) } else { throw TestFailure(message: "expected the window message", file: #fileID, line: #line) }
            resolver.clipboard = { .denied }
            if case .message(let m) = await resolver.resolve(frontmostBundleID: "com.apple.mail", settings: settings) { try expect(m.en.contains("clipboard")) } else { throw TestFailure(message: "expected the clipboard message", file: #fileID, line: #line) }
            resolver.clipboard = { .empty }
            if case .message(let m) = await resolver.resolve(frontmostBundleID: "com.apple.mail", settings: settings) { try expect(m.en.hasPrefix("Nothing to convert here") && m.ru.hasPrefix("Здесь нечего")) } else { throw TestFailure(message: "expected the nothing message", file: #fileID, line: #line) }
        }
        t.register("wheel", "permission sheets: every sheet is bilingual, explanations say Continue and recovery sheets say Open Automation Settings") {
            let kinds: [WheelPermissionKind] = [.explainBrowser(.safari), .explainFinder, .explainAccessibility, .deniedBrowser(.chrome), .deniedFinder]
            for k in kinds {
                let c = WheelPermissionCopy.copy(for: k)
                try expect(!c.title.en.isEmpty && !c.title.ru.isEmpty && !c.message.en.isEmpty && !c.message.ru.isEmpty && c.title.en != c.title.ru, "\(k) is bilingual")
                try expectEqual(c.primary.en, k.isExplanation ? "Continue" : "Open Automation Settings")
            }
            try expect(WheelPermissionCopy.copy(for: .explainBrowser(.arc)).title.en.contains("Arc"))
            try expect(WheelPermissionCopy.copy(for: .explainFinder).message == FinderSelectionReader.explanation)
        }
        t.register("wheel", "Accessibility: reading the selection never prompts; only the button does, after the explanation, and a refusal of the sheet never reaches the system") {
            let savedTrusted = AccessibilityAccess.isTrusted, savedPrompt = AccessibilityAccess.prompt
            defer { AccessibilityAccess.isTrusted = savedTrusted; AccessibilityAccess.prompt = savedPrompt; WheelPermissionPrompt.shared.stub = nil }
            let prompted = Box(0)
            AccessibilityAccess.prompt = { prompted.value += 1; return false }
            AccessibilityAccess.isTrusted = { false }
            _ = BrowserLinkReader.readSelectedText(); _ = BrowserLinkReader.shared.selectedText()
            let r = await stubReader(selected: nil, clipboard: nil).readCurrent(frontmostBundleID: BrowserKind.dia.bundleID)
            _ = r
            try expectEqual(prompted.value, 0, "reading selected text, even with nothing trusted, never shows the system alert")
            WheelPermissionPrompt.shared.stub = { _ in .notNow }
            let refused = await AccessibilityAccess.requestAfterExplaining()
            try expect(!refused); try expectEqual(prompted.value, 0, "Not Now on the sheet stops before the system call")
            var sheetKinds: [WheelPermissionKind] = []
            WheelPermissionPrompt.shared.stub = { sheetKinds.append($0); return .primary }
            _ = await AccessibilityAccess.requestAfterExplaining()
            try expectEqual(sheetKinds, [.explainAccessibility], "the explanation comes first")
            try expectEqual(prompted.value, 1, "Continue asks the system exactly once")
            AccessibilityAccess.isTrusted = { true }
            let already = await AccessibilityAccess.requestAfterExplaining()
            try expect(already); try expectEqual(prompted.value, 1, "already allowed: no sheet and no alert")
            let copy = WheelPermissionCopy.copy(for: .explainAccessibility)
            try expect(copy.message.en.contains("Dia") && copy.message.en.contains("Developer ID") && copy.message.ru.contains("Developer ID"), "the ad-hoc signing caveat is in both languages")
        }
        t.register("wheel", "Finder reader: the first read waits for the explanation, then for consent; paths become files; a denial is reported") {
            let fx = TestFixtures(label: "wheel-finder")
            defer { fx.cleanup() }
            let png = try fx.png("a.png")
            let reader = FinderSelectionReader()
            reader.consentStatus = { .notDetermined }
            reader.runScript = { _, _ in .text(png.path + "\n/does/not/exist.png\n") }
            reader.askConsent = { .granted }
            let key = "app.swampconverter.wheel.finderExplained"
            let before = UserDefaults.standard.object(forKey: key)
            defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
            UserDefaults.standard.removeObject(forKey: key)
            if case .needsExplanation = await reader.read() {} else { throw TestFailure(message: "expected the explanation first", file: #fileID, line: #line) }
            reader.markExplained()
            if case .files(let items) = await reader.read() { try expectEqual(items.map(\.url.lastPathComponent), ["a.png"], "vanished files are dropped") } else { throw TestFailure(message: "expected files", file: #fileID, line: #line) }
            reader.consentStatus = { .denied }
            if case .denied = await reader.read() {} else { throw TestFailure(message: "expected denied", file: #fileID, line: #line) }
            reader.consentStatus = { .granted }
            reader.runScript = { _, _ in .failure(number: AppleScriptOutcome.notPermitted, message: "") }
            if case .denied = await reader.read() {} else { throw TestFailure(message: "-1743 means denied", file: #fileID, line: #line) }
            reader.runScript = { _, _ in .text("") }
            if case .empty = await reader.read() {} else { throw TestFailure(message: "expected empty", file: #fileID, line: #line) }
        }
        t.register("wheel", "\"Allow Access…\" asks Finder, every named browser that shares its address, and every other installed browser") {
            let targets = AutomationAccess.targets
            try expect(targets.contains { $0.bundleID == FinderSelectionReader.finderBundleID && $0.browser == nil })
            for kind in BrowserKind.allCases where kind.exposesTabURL {
                try expect(targets.contains { $0.bundleID == kind.bundleID }, "\(kind) is one of the targets")
            }
            try expect(!targets.contains { $0.bundleID == BrowserKind.firefox.bundleID }, "Firefox has no address to ask for")
            try expect(!targets.contains { $0.bundleID == BrowserKind.dia.bundleID }, "Dia is never asked: its own answer is not trusted, so there is nothing automation consent would help with")
            // installedOtherBrowsers() must not crash and must never repeat a named bundle ID; what it actually finds depends on the machine.
            let others = BrowserKind.installedOtherBrowsers()
            let named = Set(BrowserKind.allCases.map { $0.bundleID.lowercased() })
            try expect(!others.contains { named.contains($0.bundleID.lowercased()) }, "a browser already named does not also show up as \"other\"")
            // An app that registers https for its own deep links but cannot show a web page (ChatGPT.app on the owner's Mac) is not a browser.
            let htmlViewers = Set(NSWorkspace.shared.urlsForApplications(toOpen: UTType.html).compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
            try expect(others.allSatisfy { htmlViewers.contains($0.bundleID.lowercased()) }, "every \"other\" browser can also open an HTML page")
            try expectEqual(BrowserKind.probeOther(bundleID: "com.openai.codex"), nil, "a deep-link-only https handler is never treated as a browser")
        }
    }
}
