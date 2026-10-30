import Foundation
import AppKit

// The in-app test harness: `SwampConverter --self-test [filter]` (or `./build.sh selftest [filter]`).
// No XCTest / Swift Testing needed. Tests are registered by each module's `registerSelfTests()` and run on the
// main actor, one after another, against an ISOLATED home folder (Application Support and temp are redirected by
// the CLI before anything else touches them), so nothing a test does can reach the user's real settings.
//
//   SelfTestRegistry.shared.register("image", "quality is monotonic") {
//       let fx = TestFixtures()
//       defer { fx.cleanup() }
//       let png = try fx.png(width: 64, height: 64, pattern: .gradient)
//       ...
//       try expect(small < large, "q30 must be smaller than q90")
//   }
//
// Output: one line per test (PASS / FAIL / SKIP), a summary, exit code 1 on any failure.

struct TestFailure: Error, CustomStringConvertible {
    var message: String
    var file: String
    var line: UInt
    var description: String { "\(message) (\(file):\(line))" }
}

/// Thrown by `skipTest` to report a test as skipped (missing optional tool, no window server ...).
struct TestSkip: Error { var reason: String }

// MARK: Assertions

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) throws {
    if !(try condition()) { throw TestFailure(message: message(), file: "\(file)", line: line) }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: String = "",
                               file: StaticString = #fileID, line: UInt = #line) throws {
    let a = try actual(), e = try expected()
    if a != e {
        throw TestFailure(message: "\(message.isEmpty ? "values differ" : message): got \(a), expected \(e)", file: "\(file)", line: line)
    }
}

/// `abs(actual - expected) <= tolerance`.
func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 1e-6, _ message: String = "",
                 file: StaticString = #fileID, line: UInt = #line) throws {
    if !(abs(actual - expected) <= tolerance) {
        throw TestFailure(message: "\(message.isEmpty ? "numbers differ" : message): got \(actual), expected \(expected) +/- \(tolerance)", file: "\(file)", line: line)
    }
}

func unwrap<T>(_ value: T?, _ message: String = "unexpected nil", file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(message: message, file: "\(file)", line: line) }
    return value
}

/// Runs `body` and requires it to throw; returns the error for further inspection.
@discardableResult
func expectThrows(_ message: String = "expected an error", file: StaticString = #fileID, line: UInt = #line,
                  _ body: () async throws -> Void) async throws -> Error {
    do { try await body() } catch { return error }
    throw TestFailure(message: message, file: "\(file)", line: line)
}

/// Marks the running test as skipped.
func skipTest(_ reason: String) throws -> Never { throw TestSkip(reason: reason) }

// MARK: Registry

typealias SelfTestBody = @MainActor () async throws -> Void

struct SelfTestCase {
    var suite: String
    var name: String
    /// Capability ids (Capabilities.swift); a missing one makes the test SKIP with the calm reason instead of failing.
    var requires: [String]
    var timeout: TimeInterval
    var body: SelfTestBody
    var fullName: String { "\(suite)/\(name)" }
}

struct SelfTestReport {
    var passed = 0
    var failed = 0
    var skipped = 0
    var failures: [String] = []
    var exitCode: Int32 { failed == 0 ? 0 : 1 }
}

final class SelfTestRegistry: @unchecked Sendable {
    static let shared = SelfTestRegistry()
    private let lock = NSLock()
    private var _cases: [SelfTestCase] = []

    var cases: [SelfTestCase] { lock.lock(); defer { lock.unlock() }; return _cases }

    /// `suite` is the module / component ("core.paths", "image", "pdf"); `name` states the behaviour.
    func register(_ suite: String, _ name: String, requires: [String] = [], timeout: TimeInterval = 90, _ body: @escaping SelfTestBody) {
        lock.lock(); _cases.append(SelfTestCase(suite: suite, name: name, requires: requires, timeout: timeout, body: body)); lock.unlock()
    }

    /// Tests whose "suite/name" contains `filter` (case-insensitive), or all when nil/empty.
    func selected(filter: String?) -> [SelfTestCase] {
        guard let f = filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return cases }
        return cases.filter { $0.fullName.range(of: f, options: .caseInsensitive) != nil }
    }

    /// Runs the selected tests sequentially and prints the per-test list. Returns the report; the caller exits.
    @MainActor
    func run(filter: String?) async -> SelfTestReport {
        let list = selected(filter: filter)
        var report = SelfTestReport()
        if list.isEmpty {
            out("no self-tests match \(filter.map { "'\($0)'" } ?? "(none registered)")")
            report.failed = 1
            report.failures = ["no tests selected"]
            return report
        }
        let width = min(70, max(list.map { $0.fullName.count }.max() ?? 20, 20))
        let start = Date()
        for c in list {
            let missing = c.requires.first { !Capabilities.shared.has($0) }
            if let missing {
                let why = Capabilities.reason(for: missing).en
                out("SKIP  \(pad(c.fullName, width))  \(why)")
                report.skipped += 1
                continue
            }
            let t0 = Date()
            let watchdog = Watchdog(name: c.fullName, seconds: c.timeout)
            do {
                try await c.body()
                watchdog.cancel()
                out("PASS  \(pad(c.fullName, width))  \(ms(t0))")
                report.passed += 1
            } catch let skip as TestSkip {
                watchdog.cancel()
                out("SKIP  \(pad(c.fullName, width))  \(skip.reason)")
                report.skipped += 1
            } catch {
                watchdog.cancel()
                let text = (error as? TestFailure)?.description ?? ConversionError.describe(error)
                out("FAIL  \(pad(c.fullName, width))  \(text)")
                report.failed += 1
                report.failures.append("\(c.fullName): \(text)")
            }
        }
        out("")
        out("\(report.passed) passed, \(report.failed) failed, \(report.skipped) skipped in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        if !report.failures.isEmpty {
            out("Failures:")
            report.failures.forEach { out("  - \($0)") }
        }
        return report
    }

    private func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    private func ms(_ t0: Date) -> String { String(format: "(%.2f s)", Date().timeIntervalSince(t0)) }
}

/// Kills the process when a test hangs (a synchronous hang on the main actor cannot be cancelled any other way).
private final class Watchdog: @unchecked Sendable {
    private let item: DispatchWorkItem
    init(name: String, seconds: TimeInterval) {
        item = DispatchWorkItem {
            out("TIMEOUT  \(name) did not finish within \(Int(seconds)) s; aborting the run")
            ProcessRegistry.shared.killAll()
            exit(3)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }
    func cancel() { item.cancel() }
}

/// stdout, unbuffered, so progress is visible while a long test runs.
func out(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
