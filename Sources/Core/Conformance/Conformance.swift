import Foundation

// CONFORMANCE: proof that every operation is a real converter and not a renamed copy.
//
// The suite is GENERATED from `OperationRegistry`: every registered operation gets one `conformance.<family>` self-test that runs it for real, on
// realistic fixtures, through the same resolve-and-execute path the job runner uses, and then
//   1. checks what every conversion owes (the generic checks: right format by the bytes, decodable by an independent decoder, not a byte copy of the
//      input unless the operation declares `passthrough`, input untouched, no partial files, honest naming), and
//   2. hands the run to the operation's ORACLE, which compares the output with the source (PSNR / SSIM, SNR, bit-exactness, text, grids, cues, members).
// An operation that no oracle claims FAILS `conformance.coverage`. Engines add sharper oracles with `ConformanceRegistry.shared.add`; Core ships
// default oracles for every kind of conversion (ConformanceOracles*.swift), so a new operation is covered the day it is registered.

/// One input set for one run of an operation.
struct ConformanceCase {
    var label: String
    var inputs: [URL]
    /// Options layered over the quick recipe (what Studio would add). Empty = the plain wheel run.
    var extra: OptionValues = OptionValues()
    var mode: RunMode = .quick
    /// Nothing is expected to come out (an operation that must skip these inputs).
    var expectsNoOutput = false
    /// The operation must REFUSE these inputs (a hostile archive, a corrupt file): it has to throw, leave nothing behind and touch nothing outside its folder.
    /// The oracle's `verify` then inspects `run.error` and the file system.
    var expectsFailure = false
    /// A known limitation of the platform, not of the operation: a failure of the oracle's `verify` is printed as an ADVISORY note with this explanation instead of
    /// failing the test (the generic checks still apply). Use it sparingly and only with the evidence in the text.
    var advisory: String? = nil
}

/// The checks every conversion owes. An oracle may relax one with a reason (a PDF unlock yields a PDF with the input's name, a copy is meant to be identical).
enum GenericCheck: String, CaseIterable, Sendable {
    case sniffMatchesExtension, targetFormat, decodes, notIdentical, inputsUntouched, noPartials, namedAfterInput, nonEmpty
}

struct ConformanceOracle {
    var id: String
    /// Higher wins; default family oracles are 0, engine oracles 100.
    var priority = 0
    /// The generic safety net that matches every operation. It runs the anti-fake checks but proves nothing about the content, so an operation judged by
    /// it alone is NOT covered (see `ConformanceRegistry.coveringOracle`).
    var isFallback = false
    var match: (OperationMeta) -> Bool
    /// Capability ids (`tool.ffmpeg`...) the oracle needs on top of the operation's own tools; a missing one SKIPs the test with the calm reason.
    var requires: [String] = []
    var timeout: TimeInterval = 240
    /// Realistic fixtures for this operation, created inside `fx`.
    var cases: @MainActor (OperationMeta, ConformanceFixtures) async throws -> [ConformanceCase]
    /// Compares output with input. Throws a `TestFailure` (use `expect`) when the output is not what the operation claims.
    var verify: @MainActor (ConformanceRun) async throws -> Void
    var relaxed: [GenericCheck: String] = [:]
    /// Short statement of what this oracle proves; printed with the coverage report.
    var proves: String = ""
}

/// What a finished run looks like to an oracle.
final class ConformanceRun {
    let operation: Operation
    let testCase: ConformanceCase
    /// The copies of the inputs the operation actually read (next to which its outputs were written).
    let inputs: [URL]
    /// Folder holding the inputs and (usually) the outputs.
    let workDir: URL
    let result: OperationResult
    /// Everything the operation produced, folders expanded into the regular files below them (sorted, hidden files left out).
    let outputs: [URL]
    /// Exactly what the operation returned (files and folders).
    var returned: [URL] { result.outputs }
    let options: OptionValues
    /// Keys of options that were inactive in this run (disabled by a condition or a missing capability): the engine ignored them.
    let inactive: Set<String>
    let log: [String]
    /// Every progress value the operation reported (nil entries, indeterminate, are left out).
    let progress: [Double]
    let seconds: Double
    let fx: ConformanceFixtures
    /// The calm message of the error the operation threw (only for cases with `expectsFailure`).
    let error: String?
    private(set) var notes: [String] = []

    var meta: OperationMeta { operation.meta }
    var input: URL { inputs[0] }
    var output: URL { outputs[0] }

    init(operation: Operation, testCase: ConformanceCase, inputs: [URL], workDir: URL, result: OperationResult, outputs: [URL], options: OptionValues,
         log: [String], progress: [Double], seconds: Double, fx: ConformanceFixtures, error: String? = nil, inactive: Set<String> = []) {
        self.operation = operation; self.testCase = testCase; self.inputs = inputs; self.workDir = workDir; self.result = result; self.outputs = outputs
        self.options = options; self.log = log; self.progress = progress; self.seconds = seconds; self.fx = fx; self.error = error; self.inactive = inactive
    }

    /// Evidence line printed under the test ("PSNR 38.2 dB, 41 KB").
    func note(_ s: String) { notes.append(s) }
    func outputs(withExtension ext: String) -> [URL] { outputs.filter { Formats.key(of: $0) == ext } }
}

enum ConformanceExemption {
    /// Operations that have no file output to judge, with the reason.
    static let defaults: [(match: (OperationMeta) -> Bool, reason: String)] = [
        ({ $0.isAppAction }, "runs in the app and produces no converted file (Actions wheel)"),
        ({ $0.id.hasPrefix("preset.") || $0.id.hasPrefix("chain.") }, "a user preset or chain; it runs registered operations that are covered themselves"),
        ({ $0.id.hasPrefix("multi.") }, "a multi-output pack; it runs registered operations that are covered themselves, and the automation tests judge its fan-out, names and folders"),
        ({ $0.acceptsLinks }, "downloads need the network; the downloader module verifies them with a fake yt-dlp")]
}

final class ConformanceRegistry: @unchecked Sendable {
    static let shared = ConformanceRegistry()
    private let lock = NSLock()
    private var oracles: [ConformanceOracle] = []
    private var exemptions: [(id: String, reason: String)] = []
    private var builtinsLoaded = false

    init(includeBuiltins: Bool = true) { builtinsLoaded = !includeBuiltins }

    /// Adds an oracle. Engines call this from `registerSelfTests()`; lookup happens when the tests run, so order does not matter.
    func add(_ o: ConformanceOracle) {
        lock.lock(); oracles.removeAll { $0.id == o.id }; oracles.append(o); lock.unlock()
    }

    /// Declares that operations whose id equals `idOrPrefix` (or starts with it when it ends in ".") are not judged here, and why.
    func exempt(_ idOrPrefix: String, reason: String) {
        lock.lock(); exemptions.append((idOrPrefix, reason)); lock.unlock()
    }

    func oracle(for meta: OperationMeta) -> ConformanceOracle? {
        loadBuiltinsIfNeeded()
        lock.lock(); let list = oracles; lock.unlock()
        var best: ConformanceOracle?
        for o in list where o.match(meta) { if best == nil || o.priority > best!.priority { best = o } }
        return best
    }

    /// The oracle that actually judges the content of `meta`'s output: `oracle(for:)` without the generic fallback. Nil = not covered.
    func coveringOracle(for meta: OperationMeta) -> ConformanceOracle? {
        loadBuiltinsIfNeeded()
        lock.lock(); let list = oracles; lock.unlock()
        var best: ConformanceOracle?
        for o in list where !o.isFallback && o.match(meta) { if best == nil || o.priority > best!.priority { best = o } }
        return best
    }

    func exemption(for meta: OperationMeta) -> String? {
        lock.lock(); let ex = exemptions; lock.unlock()
        for e in ex where meta.id == e.id || (e.id.hasSuffix(".") && meta.id.hasPrefix(e.id)) { return e.reason }
        return ConformanceExemption.defaults.first { $0.match(meta) }?.reason
    }

    var allOracles: [ConformanceOracle] { loadBuiltinsIfNeeded(); lock.lock(); defer { lock.unlock() }; return oracles }

    /// Tests only: forget everything (built-ins load again on the next lookup).
    func reset() { lock.lock(); oracles = []; exemptions = []; builtinsLoaded = false; lock.unlock() }

    private func loadBuiltinsIfNeeded() {
        lock.lock()
        if builtinsLoaded { lock.unlock(); return }
        builtinsLoaded = true
        lock.unlock()
        ConformanceOracles.registerBuiltins(into: self)
    }
}
