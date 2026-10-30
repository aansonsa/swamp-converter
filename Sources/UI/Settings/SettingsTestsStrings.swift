import Foundation

// Self-test of the words on the Settings pages: every L("English", "Русский") has two real languages, no exclamation marks, no three-dot ellipsis; files stay short and quiet.

extension SettingsTests {
    static func registerStringTests(_ t: SelfTestRegistry) {
        t.register("settings.strings", "every L(en, ru) on the Settings pages has two real languages, no exclamation marks, no three-dot ellipsis") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            let dir = sources.appendingPathComponent("UI/Settings")
            let pair = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)"#)
            let pair10 = try NSRegularExpression(pattern: #"\bL10n\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)"#)
            let properNames: Set<String> = ["Homebrew"]   // product names are written the same in both languages
            var checked = 0
            var problems: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: dir) where !path.contains("Tests") && !path.contains("/ThirdParty/") {
                let ns = text as NSString
                let file = URL(fileURLWithPath: path).lastPathComponent
                for m in pair.matches(in: text, range: NSRange(location: 0, length: ns.length)) + pair10.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let en = ns.substring(with: m.range(at: 1)), ru = ns.substring(with: m.range(at: 2))
                    checked += 1
                    if properNames.contains(en) && en == ru { continue }
                    let interpolation = en.hasPrefix("\\(") || ru.hasPrefix("\\(")
                    if en == ru && en.rangeOfCharacter(from: .letters) != nil && !interpolation { problems.append("\(file): same in both languages: \(en)") }
                    if !ru.unicodeScalars.contains(where: { $0.value >= 0x400 && $0.value <= 0x4FF }) && ru.rangeOfCharacter(from: .letters) != nil && !interpolation {
                        problems.append("\(file): no Cyrillic in \(ru)")
                    }
                    for s in [en, ru] where s.contains("!") || s.contains("...") { problems.append("\(file): '!' or '...' in \(s)") }
                }
            }
            try expect(checked > 60, "only \(checked) strings found: the pattern broke")
            try expect(problems.isEmpty, "\(problems.count) problem(s):\n" + problems.prefix(12).joined(separator: "\n"))
        }

        t.register("settings.strings", "module hygiene: files stay under 500 lines; no timers or polling in production files") {
            guard let sources = SharedTestKit.sourcesRoot() else { try skipTest("the source tree is not next to this binary") }
            var problems: [String] = []
            for (path, text) in SharedTestKit.swiftSources(in: sources.appendingPathComponent("UI/Settings")) where !path.contains("/ThirdParty/") {
                let file = URL(fileURLWithPath: path).lastPathComponent
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > 500 { problems.append("\(file): \(lines.count) lines") }
                if file.contains("Tests") { continue }
                for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    for bad in ["Timer.scheduled", "Timer(", "CADisplayLink", "TimelineView", "repeatForever", "TODO", "fatalError"] where line.contains(bad) {
                        problems.append("\(file):\(i + 1): \(bad)")
                    }
                }
            }
            try expect(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        }
    }
}
