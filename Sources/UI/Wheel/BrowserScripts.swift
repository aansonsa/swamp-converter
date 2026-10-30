import Foundation

/// Pure AppleScript text generators and parsers (golden-tested with fixtures; never executed in tests). One script returns "<url>\n<title>" of the active tab
/// of the front window of a browser; another returns the Finder selection as POSIX paths, one per line.
enum BrowserScripts {
    /// What the tab script returns when the browser has no window.
    static let noWindowMarker = "__swamp_no_window__"
    /// AppleScript-side time limit; the Swift side gives up a little later (`BrowserLinkReader.scriptTimeout`).
    static let scriptSeconds = 1

    /// Returns "<url>\n<title>" of the active tab of the front window. Safari family: `URL of current tab of front window` / `name of current tab of front window`;
    /// Chromium family: `URL of active tab of front window` / `title of active tab of front window`; Arc: also try its own dictionary (`URL of active tab of front window`
    /// first, then the Safari-style `current tab` words). Quotes in the application name are escaped. nil for Firefox (no URL).
    static func activeTabScript(for browser: BrowserKind) -> String? {
        guard browser.exposesTabURL else { return nil }
        let app = escape(browser.appleScriptName)
        let urlWords: String, titleWords: String
        if browser.isSafariFamily {
            urlWords = "URL of current tab of front window"
            titleWords = "name of current tab of front window"
        } else {
            urlWords = "URL of active tab of front window"
            titleWords = "title of active tab of front window"
        }
        var lines: [String] = [
            "with timeout of \(scriptSeconds) seconds",
            "tell application \"\(app)\"",
            "if (count of windows) is 0 then return \"\(noWindowMarker)\"",
            "set theURL to \"\"",
            "set theTitle to \"\"",
            "try",
            "set theURL to \(urlWords)",
            "end try",
            "try",
            "set theTitle to \(titleWords)",
            "end try"
        ]
        if browser == .arc {
            // Arc's own dictionary names the tab "active tab"; older builds answer to the Safari words. Try the second pair only when the first gave nothing.
            lines += [
                "if theURL is missing value or theURL is \"\" then",
                "try",
                "set theURL to URL of current tab of front window",
                "set theTitle to name of current tab of front window",
                "end try",
                "end if"
            ]
        }
        lines += [
            "if theURL is missing value then set theURL to \"\"",
            "if theTitle is missing value then set theTitle to \"\"",
            "return theURL & linefeed & theTitle",
            "end tell",
            "end timeout"
        ]
        return lines.joined(separator: "\n")
    }

    /// The Finder selection as POSIX paths, one per line (`tell application "Finder" to get selection as alias list`, rendered as text so parsing is pure).
    static func finderSelectionScript() -> String {
        [
            "with timeout of \(scriptSeconds) seconds",
            "tell application \"Finder\"",
            "set theSelection to selection as alias list",
            "set theResult to \"\"",
            "repeat with oneItem in theSelection",
            "set theResult to theResult & POSIX path of oneItem & linefeed",
            "end repeat",
            "return theResult",
            "end tell",
            "end timeout"
        ].joined(separator: "\n")
    }

    /// Escapes a string for use inside an AppleScript string literal (backslash and double quote; line breaks become spaces).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 4)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    /// Parses the tab script's text result ("url\ntitle") back; rejects an empty / missing value, the no-window marker and anything without a scheme.
    static func parseResult(_ text: String) -> (url: URL, title: String?)? {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty,
              first != noWindowMarker, first != "missing value",
              let url = URL(string: first), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        let title = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (url, title.isEmpty || title == "missing value" ? nil : title)
    }

    /// True when the tab script said the browser has no window.
    static func isNoWindow(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(noWindowMarker) }

    /// Parses the Finder script's text: absolute paths only, duplicates removed, order kept.
    static func parseFinderSelection(_ text: String) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for raw in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/"), path.count > 1 else { continue }
            let url = URL(fileURLWithPath: path)
            if seen.insert(url.standardizedFileURL.path).inserted { out.append(url) }
        }
        return out
    }
}
