import Foundation
import AppKit
import CoreServices

// The one place that executes AppleScript and asks about Automation consent. A script runs as its own `osascript` process with a hard, enforced-by-killing
// time limit, so a hung browser can never freeze the wheel; consent runs on a background queue with its own time limit. The script texts come from
// `BrowserScripts` (pure, golden-tested); `run` is exercised for real by a test in `WheelTestsBrowser.swift` (it is the one function here worth running
// unstubbed), everything else is used through a stub in tests.

enum AppleScriptOutcome: Equatable, Sendable {
    case text(String)
    /// AppleScript error number (-1743 not allowed, -1728 no such object, -600 app not running, -1712 timed out ...) and its message.
    case failure(number: Int, message: String)
    /// The Swift-side limit expired first (the script thread may still be running; its result is dropped).
    case timedOut

    static let notPermitted = -1743
    static let appleEventTimedOut = -1712
    static let appNotRunning = -600
    static let wouldRequireConsent = -1744
    static let canNotGetObject = -1728
    /// The target has no handler for the event at all — a browser whose own dictionary never learned this verb (an unrecognised browser guessed at the
    /// Chromium words, or a real browser whose current build dropped AppleScript support), as opposed to a window problem.
    static let eventNotHandled = -1708
}

enum AppleScriptRunner {
    /// Replaceable in tests: runs a script and returns the outcome without touching AppleScript.
    nonisolated(unsafe) static var stub: (@Sendable (String) -> AppleScriptOutcome)?

    /// Runs `source` as a background `osascript` process; gives up after `timeout` seconds by killing it.
    ///
    /// This used to run in-process with `NSAppleScript`, racing the call against a Swift-side timer. That is NOT safe: a target that is slow to answer one
    /// Apple Event (seen for real against a browser whose automation bridge was momentarily busy) can leave `executeAndReturnError` blocked on its calling
    /// thread for a very long time, and a timer racing it from a different queue is not a reliable way to bound that — it can simply never fire while the
    /// call is stuck, which froze the wheel hotkey completely (`hotkeyBusy` never clears) with no error shown at all. A subprocess has no such failure mode:
    /// `timeout` is enforced by terminating the process outright (SIGTERM, then SIGKILL if it ignores that), which unconditionally ends whatever it was
    /// stuck on. The script text itself still carries `with timeout of N seconds` (`BrowserScripts`) as the target application's own first line of defense;
    /// this is the backstop that holds even when that fails.
    static func run(_ source: String, timeout: TimeInterval) async -> AppleScriptOutcome {
        if let stub { return stub(source) }
        return await withCheckedContinuation { (cont: CheckedContinuation<AppleScriptOutcome, Never>) in
            let gate = OnceGate(cont)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]                                        // read the script from stdin; no shell, no quoting concerns
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    gate.resume(.text(outText.trimmingCharacters(in: .newlines)))
                } else {
                    gate.resume(.failure(number: errorNumber(in: errText) ?? Int(proc.terminationStatus), message: errText))
                }
            }
            do {
                try process.run()
            } catch {
                gate.resume(.failure(number: 0, message: "\(error)"))
                return
            }
            stdin.fileHandleForWriting.write(Data(source.utf8))
            try? stdin.fileHandleForWriting.close()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                gate.resume(.timedOut)
            }
        }
    }

    /// The error number `osascript` prints at the end of a runtime-error line ("... got an error: ... (-1712)"); nil for anything else (a syntax error, say).
    private static func errorNumber(in stderrText: String) -> Int? {
        let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else { return nil }
        return Int(trimmed[trimmed.index(after: open)..<close])
    }

    /// Compiles without running (syntax check: sends no Apple events and shows no consent dialog). nil = compiled; otherwise the message.
    static func compileError(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        if script?.compileAndReturnError(&error) == true { return nil }
        return (error?["NSAppleScriptErrorMessage"] as? String) ?? "could not compile"
    }

    // MARK: Automation consent

    enum Consent: Equatable, Sendable { case granted, denied, notDetermined, targetNotRunning, failed(Int32) }

    /// `AEDeterminePermissionToAutomateTarget`. With `ask == false` it never shows a dialog and returns at once; with `ask == true` it BLOCKS until the person
    /// answers, so call it only off the main thread (see `consent(for:ask:)`).
    nonisolated static func consentSync(bundleID: String, ask: Bool) -> Consent {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        return map(status)
    }

    nonisolated static func map(_ status: OSStatus) -> Consent {
        switch Int(status) {
        case 0: return .granted
        case AppleScriptOutcome.notPermitted: return .denied
        case AppleScriptOutcome.wouldRequireConsent: return .notDetermined
        case AppleScriptOutcome.appNotRunning: return .targetNotRunning
        default: return .failed(status)
        }
    }

    /// Off-main wrapper: asks (and waits for the person) when `ask` is true.
    static func consent(for bundleID: String, ask: Bool) async -> Consent {
        await withCheckedContinuation { (cont: CheckedContinuation<Consent, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: consentSync(bundleID: bundleID, ask: ask)) }
        }
    }
}

/// Resumes a continuation exactly once, whichever of two racing callers gets there first.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
