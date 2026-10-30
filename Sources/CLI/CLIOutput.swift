import Foundation

/// Captures what a command wrote, for the in-process self-tests (`CLI.run(arguments:environment:sink:)`). The real process writes to the file descriptors instead.
final class CLISink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func writeOut(_ s: String) { lock.lock(); out.append(Data(s.utf8)); lock.unlock() }
    func writeErr(_ s: String) { lock.lock(); err.append(Data(s.utf8)); lock.unlock() }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    /// stdout split into lines (no empty trailing line).
    var stdoutLines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    /// Every stdout line parsed as a JSON object (nil entries for lines that are not JSON objects).
    var stdoutObjects: [[String: Any]?] { stdoutLines.map { CLIJSON.parseObject($0) } }
}

/// Machine-readable output. JSON Lines on stdout in `--json` mode; human text otherwise. Never writes to stdout from anywhere else (stdout is the contract).
///
/// stdout: the result (one path per line in human mode; JSON in `--json` mode). stderr: progress, warnings, notes, errors in human mode.
/// In `--json` mode errors and warnings are events on stdout as well, so a script reads ONE stream.
struct CLIOutput {
    var json: Bool
    /// Indent single-document JSON (list-ops, probe, options ...). Events always stay on one line.
    var pretty = false
    var quiet = false
    var verbose = false
    /// Where bytes go. nil: the file descriptors below.
    var sink: CLISink? = nil
    var outFD: Int32 = 1
    var errFD: Int32 = 2
    /// stderr is a terminal: progress redraws one line instead of printing steps.
    var interactive = false

    // MARK: Primitives

    func writeOut(_ s: String) {
        if let sink { sink.writeOut(s) } else { CLIOutput.write(fd: outFD, s) }
    }
    func writeErr(_ s: String) {
        if let sink { sink.writeErr(s) } else { CLIOutput.write(fd: errFD, s) }
    }

    /// One line on stdout.
    func line(_ s: String) { writeOut(s + "\n") }
    /// One line on stderr (human messages).
    func note(_ s: String) { writeErr(s + "\n") }

    private static func write(fd: Int32, _ s: String) {
        var bytes = Array(s.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }   // a closed pipe ends the output quietly
            bytes = bytes.dropFirst(n)
        }
    }

    // MARK: Events (JSON mode)

    /// `{"event":"<name>", ...fields}` as one line on stdout. Nothing in human mode.
    func event(_ name: String, _ fields: [String: Any]) {
        guard json else { return }
        var obj = fields
        obj["event"] = name
        line(CLIJSON.string(obj, pretty: false))
    }

    /// Progress of a job. JSON: `{"event":"progress","job","fraction","stage","eta","message"}` (null where unknown). Human: a line on stderr.
    func progress(job: String, fraction: Double?, stage: String?, eta: TimeInterval?, message: String?) {
        if json {
            event("progress", ["job": job, "fraction": fraction as Any, "stage": stage as Any, "eta": eta as Any, "message": message as Any])
            return
        }
        guard !quiet else { return }
        var parts: [String] = []
        if let stage, !stage.isEmpty { parts.append(stage) }
        if let fraction { parts.append(Loc.percent(Int((fraction * 100).rounded()))) }
        if let eta, eta > 0.5 { parts.append(Util.formatDuration(eta)) }
        if let message, !message.isEmpty, parts.isEmpty { parts.append(message) }
        guard !parts.isEmpty else { return }
        let text = parts.joined(separator: "  ")
        if interactive { writeErr("\r\u{1B}[K" + text) } else { note(text) }
    }

    /// Ends an interactive progress line.
    func finishProgress() { if !json && interactive && !quiet { writeErr("\r\u{1B}[K") } }

    func result(outputs: [URL], failures: [String], note: String?) {
        done(job: nil, outputs: outputs, failures: failures, warnings: [], note: note, code: failures.isEmpty ? .ok : .partial)
    }

    /// The final answer of a conversion or download. JSON: `{"event":"done","job","outputs","failures","warnings","note","code"}`.
    /// Human: result paths on stdout (one per line), failures and the note on stderr.
    func done(job: String?, outputs: [URL], failures: [String], warnings: [String], note: String?, code: CLIExitCode, elapsed: TimeInterval? = nil) {
        if json {
            event("done", ["job": job as Any, "outputs": outputs.map(\.path), "failures": failures, "warnings": warnings, "note": note as Any,
                           "code": Int(code.rawValue), "elapsed": elapsed as Any])
            return
        }
        finishProgress()
        for f in failures { self.note(L("Failed: ", "Ошибка: ") + f) }
        if let note, !note.isEmpty, !quiet { self.note(note) }
        for url in outputs { line(url.path) }
    }

    func warning(_ message: String, key: String? = nil) {
        if json { event("warning", ["message": message, "key": key as Any]) } else { note(L("Warning: ", "Внимание: ") + message) }
    }

    /// A line of the job log (only with --verbose).
    func log(_ text: String) {
        guard verbose else { return }
        if json { event("log", ["message": text]) } else { note("  " + text) }
    }

    /// Usage, unavailable, failed ... JSON: `{"event":"error","code","message"}` on stdout. Human: `swamp: message` on stderr.
    func error(code: CLIExitCode, message: String) {
        if json {
            event("error", ["code": Int(code.rawValue), "message": message])
        } else {
            finishProgress()
            note("swamp: " + message)
        }
    }

    // MARK: Documents

    /// Pretty or compact JSON of any Codable / dictionary for list-ops, probe, presets, options. One document, on stdout.
    func print(json value: Any) {
        line(CLIJSON.string(value, pretty: pretty))
    }
}

/// JSON helpers: plain Swift values and the app's own types become something `JSONSerialization` accepts.
enum CLIJSON {
    static func string(_ value: Any, pretty: Bool) -> String {
        let clean = sanitize(value)
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(clean) || !(clean is [Any] || clean is [String: Any]),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseObject(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Values -> JSON-safe values: NaN and infinity become null, URLs paths, dates ISO 8601, `OptionValue`s plain JSON, `L10n` an {en, ru} object.
    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let i as Int64: return i
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let u as URL: return u.path
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let o as OptionValue: return optionValue(o)
        case let l as L10n: return ["en": l.en, "ru": l.ru]
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        case let m as [String: OptionValue]: return m.mapValues(optionValue)
        case is NSNull: return NSNull()
        default:
            let mirror = Mirror(reflecting: v)
            if mirror.displayStyle == .optional {
                if let child = mirror.children.first { return sanitize(child.value) }
                return NSNull()
            }
            return String(describing: v)
        }
    }

    static func optionValue(_ v: OptionValue) -> Any {
        switch v {
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .list(let l): return l.map(optionValue)
        case .rows(let r): return r.map { $0.mapValues(optionValue) }
        }
    }
}
