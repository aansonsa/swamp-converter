import SwiftUI
import AppKit

// Lint-style self-tests: the rules of the brief that are cheapest to keep by machine. Microcopy of the shared components, raw colours and the forbidden
// project name anywhere in Sources/, and the "nothing runs at idle" rule for this module.

extension SharedTests {
    /// Files that may build colours from raw numbers: the design system itself and these tests. Image engines work with pixel colours the person chose
    /// (a background for transparency), which are data, not interface colours, so only the interface folders are linted.
    private static let rawColourAllowList = ["/UI/Shared/DesignSystem/", "/UI/Shared/SharedTests"]
    /// Test and fixture files use colours as DATA (a hex string to parse, a swatch to compare), never as interface skin. `*SnapshotAssets*` files paint
    /// the synthetic sample pictures (a fake photo, a video frame) that snapshots show; nothing in them reaches the app's own interface.
    private static func isTestFile(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasSuffix("Tests.swift") || name.contains("Fixture") || name.contains("TestKit") || name.contains("SnapshotAssets") || path.contains("/Tests/")
    }
    private static let interfaceFolders = ["/UI/", "/App/", "/Actions/", "/Automation/"]

    static func registerLint(_ t: SelfTestRegistry) {
        t.register("shared", "microcopy of the shared components: both languages, Cyrillic Russian, no exclamation marks, no three-dot ellipsis, no emoji") {
            for s in SharedStrings.all {
                try expect(!s.en.isEmpty && !s.ru.isEmpty, "empty string \(s)")
                try expect(s.en != s.ru, "RU equals EN: \(s.en)")
                try expect(s.ru.unicodeScalars.contains { $0.value >= 0x400 && $0.value <= 0x4FF }, "Russian text without Cyrillic: \(s.ru)")
                for text in [s.en, s.ru] {
                    try expect(!text.contains("!"), "exclamation mark in \(text)")
                    try expect(!text.contains("..."), "use the ellipsis character in \(text)")
                    try expect(!text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "emoji in \(text)")
                }
            }
        }

        t.register("shared", "the raw-colour rule flags styling literals and the brand hex values, and leaves option data and variable colours alone") {
            let flagged = [
                #"Text("x").foregroundStyle(Color(red: 1, green: 0.4, blue: 0.85))"#,
                #"let c = NSColor(srgbRed: 0.5, green: 0.1, blue: 0.2, alpha: 1)"#,
                #"layer.borderColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)"#,
                #"view.background(Color(white: 0.9))"#,
                ##".fill(Color(hex: "#112233"))"##,
                ##".foregroundStyle(Color(nsColor: NSColor(hex: "#112233")))"##,
                #".tint(Color(0x112233))"#,
                ##"let pink = "#FF72D9""##,
                #"let pink = 0xff72d9"#,
                #"static let blue = RGB8(0x7D, 0xA7, 0xD9) // 7DA7D9"#
            ]
            let allowed = [
                #"return Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: 1)"#,
                ##".color(Keys.bg, L10n("Background color", "Цвет фона"), def: "#000000").standard()"##,
                ##"let defaultBackground = "#FFFFFF""##,
                #"Text("Use #112233 as the colour")"#,
                #".foregroundStyle(Brand.pinkInk)"#,
                #"NSColor(named: "AccentColor")"#
            ]
            for line in flagged { try expect(SharedLint.rawColour(in: line), "should be flagged: \(line)") }
            for line in allowed { try expect(!SharedLint.rawColour(in: line), "should be allowed: \(line)") }
        }

        t.register("shared", "no raw colours in the interface folders outside the design system (every module uses Brand / DS tokens), and the old project name never appears") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            var problems: [String] = []
            let banned = "swee" + "tch"
            // The credit line of the About window ("Inspired by ... (MIT)") is the one sanctioned mention of the project this app was inspired by, and its test.
            let creditFiles = ["App/About.swift", "App/AppShellTests.swift"]
            for (path, text) in SharedTestKit.swiftSources(in: sources) {
                let mayNameCredit = creditFiles.contains { path.hasSuffix($0) }
                let isInterface = interfaceFolders.contains { path.contains($0) } && !rawColourAllowList.contains(where: { path.contains($0) }) && !isTestFile(path)
                // Cheap whole-file pre-checks: only files that can contain a problem are scanned line by line.
                let mayHaveRawColour = isInterface && SharedLint.mayContainRawColour(text)
                let mayHaveName = !mayNameCredit && text.range(of: banned, options: .caseInsensitive) != nil
                guard mayHaveRawColour || mayHaveName else { continue }
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let s = String(line)
                    if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    if isInterface, SharedLint.rawColour(in: s) {
                        problems.append("\(path.replacingOccurrences(of: sources.path, with: "Sources")):\(i + 1): raw colour: \(s.trimmingCharacters(in: .whitespaces).prefix(90))")
                    }
                    if !mayNameCredit, s.lowercased().contains(banned) { problems.append("\(path.replacingOccurrences(of: sources.path, with: "Sources")):\(i + 1): forbidden project name") }
                }
            }
            try expect(problems.isEmpty, "\(problems.count) problem(s):\n  " + problems.prefix(12).joined(separator: "\n  "))
        }

        t.register("shared", "the three-dot rule flags an ellipsis typed as dots in a visible string, and leaves ranges and code alone") {
            let flagged = [#"Button(L("Choose...", "Выбрать..."))"#, #"Text(L("Loading...", "Загрузка…"))"#, #".help(L10n("Open...", "Открыть…").text)"#]
            let allowed = [#"Text(L("Choose…", "Выбрать…"))"#, #"let r = 1...5"#, #"L("out of range \(a)...\(b)", "вне диапазона")"#, #"let tail = s[i...]"#, #"// L("Choose...", "x")"#]
            for line in flagged { try expect(SharedLint.threeDots(in: line), "should be flagged: \(line)") }
            for line in allowed { try expect(!SharedLint.threeDots(in: line), "should be allowed: \(line)") }
        }

        t.register("shared", "every visible string in Sources uses the ellipsis character, never three dots") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            var problems: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: sources) where text.contains("...") {
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where SharedLint.threeDots(in: String(line)) {
                    problems.append("\(path.replacingOccurrences(of: sources.path, with: "Sources")):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(90))")
                }
            }
            try expect(problems.isEmpty, "\(problems.count) string(s) with three dots:\n  " + problems.prefix(12).joined(separator: "\n  "))
        }

        t.register("shared", "idle cost: the shared module has no timers, display links, sleeps or polling; the one repeating animation is the indeterminate progress bar") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            let dir = sources.appendingPathComponent("UI/Shared")
            let forbidden = ["Timer.scheduled", "Timer(", "CADisplayLink", "makeTimerSource", "DispatchSource.makeTimer", "Task.sleep", "TimelineView", "asyncAfter", "performSelector"]
            var problems: [String] = []
            var repeating: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: dir) where !path.contains("/SharedTests") && !path.hasSuffix("SharedTestKit.swift") {
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let s = String(line)
                    if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    for f in forbidden where s.contains(f) { problems.append("\(URL(fileURLWithPath: path).lastPathComponent):\(i + 1): \(f)") }
                    if s.contains(".repeatForever(") || s.contains("repeatCount = .infinity") { repeating.append(URL(fileURLWithPath: path).lastPathComponent) }
                }
            }
            try expect(problems.isEmpty, "idle-cost risks: " + problems.joined(separator: ", "))
            try expectEqual(repeating.sorted(), ["ProgressRing.swift", "SlantedProgressBar.swift"], "repeating animations (only while a progress indicator is on screen)")
        }

        t.register("shared", "module size: every shared source file stays under 500 lines") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            for (path, text) in SharedTestKit.swiftSources(in: sources.appendingPathComponent("UI/Shared")) {
                let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
                try expect(n <= 500, "\(URL(fileURLWithPath: path).lastPathComponent) has \(n) lines")
            }
        }
    }
}

/// The raw-colour rule as pure functions (fixture-tested above). What it targets: colours written into the INTERFACE code as numbers or hex, which is how a private skin
/// sneaks past the design system. What it leaves alone: a colour the person chose, converted from variables; option defaults ("#000000" as the default background of an
/// image) which are data; and anything in prose or strings that is not a styling call.
enum SharedLint {
    private static let brandHex = try! NSRegularExpression(pattern: #"(?i)(#|0x)?(FF72D9|7DA7D9)\b"#)
    private static let number = #"\s*\.?[0-9]"#
    /// Numeric colour initialisers: `Color(red: 1, ...)`, `NSColor(srgbRed: 0.5, ...)`, `CGColor(red: 0, ...)`, `Color(white: 0.9)`.
    private static let literalInit = try! NSRegularExpression(pattern: "(" + [
        #"\bColor\(\s*(\.sRGB\s*,\s*)?red:"# + number, #"\bNSColor\(\s*(srgbRed|red|calibratedRed|deviceRed):"# + number, #"\bCGColor\(\s*(srgbRed|red):"# + number,
        #"\bColor\(\s*white:"# + number
    ].joined(separator: "|") + ")")
    /// A hex literal (a "#RRGGBB" string or a 0xRRGGBB number) ...
    private static let hexLiteral = try! NSRegularExpression(pattern: ##""#[0-9A-Fa-f]{6}"|\b0x[0-9A-Fa-f]{6}\b"##)
    /// ... only counts when the same line styles something with it.
    private static let stylingContext = try! NSRegularExpression(pattern: #"\b(Color|NSColor|CGColor|foregroundStyle|foregroundColor|tint|fill|stroke|background|borderColor|backgroundColor)\b"#)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    static func rawColour(in line: String) -> Bool {
        has(literalInit, line) || has(brandHex, line) || (has(hexLiteral, line) && has(stylingContext, line))
    }

    private static let stringLiteral = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

    /// True when a (non-comment) line passes a string literal with an ellipsis typed as three dots to `L(` / `L10n(` / `Text(`: the typographic character "…" is the rule.
    /// A literal with a numeric range ("\(a)...\(b)", "1...5") or the bare string "..." is code, not copy.
    static func threeDots(in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.contains("..."), !trimmed.hasPrefix("//"), line.contains("L(") || line.contains("L10n(") || line.contains("Text(") else { return false }
        if line.range(of: #"\\\([^)]*""#, options: .regularExpression) != nil { return false }
        for m in stringLiteral.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let r = Range(m.range(at: 1), in: line) else { continue }
            let body = String(line[r])
            guard body.contains("..."), body.trimmingCharacters(in: .whitespaces) != "..." else { continue }
            if body.range(of: #"\.\.\.\\\(|\\\([^)]*\)\.\.\.|\d\.\.\.\d|\.\.\.[/\]]"#, options: .regularExpression) != nil { continue }
            return true
        }
        return false
    }

    /// Whole-file pre-filter: a file with none of the three ingredients cannot contain a raw colour.
    static func mayContainRawColour(_ text: String) -> Bool { has(literalInit, text) || has(brandHex, text) || has(hexLiteral, text) }
}
