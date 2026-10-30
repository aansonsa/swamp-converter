import Foundation

// LibreOffice headless (spec/backends.md 3.5, catalog 3.5). One instance at a time (all runs share one private profile and LibreOffice refuses a second instance on it); the
// gate is cancellation-aware, so a queued run that is cancelled leaves the queue at once. The profile lives in our own support folder, never in the person's LibreOffice
// profile. A watchdog stops a hung instance; Task cancellation kills the whole process tree (soffice and soffice.bin) through the job's process set.

/// A FIFO mutex for async code. `acquire` throws `CancellationError` when the waiting task is cancelled.
final class DocAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var queue: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                if !held { held = true; lock.unlock(); c.resume(); return }
                queue.append((id, c))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = queue.firstIndex { $0.id == id }
            let waiter = index.map { queue.remove(at: $0) }
            lock.unlock()
            waiter?.cont.resume(throwing: CancellationError())
        }
    }

    func release() {
        lock.lock()
        if queue.isEmpty { held = false; lock.unlock(); return }
        let next = queue.removeFirst()
        lock.unlock()
        next.cont.resume()
    }

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return held }
}

enum DocOffice {
    static let gate = DocAsyncGate()
    /// Seconds after which a LibreOffice run is abandoned (a hung instance on a damaged file must not block the queue forever).
    nonisolated(unsafe) static var timeoutSeconds: Double = 600

    static let failureMessage = L10n("LibreOffice could not convert the file (is it intact and not password-protected?).",
                                     "LibreOffice не удалось конвертировать файл. Возможно, он повреждён или защищён паролем.")

    /// Export filter argument of `--convert-to` for a target format (the part after ":" selects LibreOffice's filter).
    static func convertTo(_ target: String) -> String {
        switch target {
        case "docx": return "docx:MS Word 2007 XML"
        case "pptx": return "pptx:Impress MS PowerPoint 2007 XML"
        case "xlsx": return "xlsx:Calc MS Excel 2007 XML"
        case "txt": return "txt:Text"
        default: return target
        }
    }

    /// The `argv` for one conversion (a pure function so the golden tests need no LibreOffice).
    static func arguments(input: URL, convertTo filter: String, outputDirectory: URL, profile: URL, infilter: String? = nil) -> [String] {
        var a = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore", "--nolockcheck", "--nodefault"]
        if let infilter { a.append("--infilter=" + infilter) }
        a += ["--convert-to", filter, "--outdir", outputDirectory.path, input.path]
        return a
    }

    static func profileDirectory() -> URL {
        let d = AppPaths.supportDir.appendingPathComponent("lo-profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Converts `input` and returns the produced file inside `outputDirectory` (named after the input with the new extension).
    static func convert(input: URL, filter: String, outputDirectory: URL, ctx: OperationContext, infilter: String? = nil) async throws -> URL {
        let soffice = try ctx.tools.require(.soffice)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try await gate.acquire()
        defer { gate.release() }
        let ext = String(filter.split(separator: ":", maxSplits: 1).first ?? "")
        let expected = outputDirectory.appendingPathComponent(Formats.baseName(of: input) + "." + ext)
        func attempt() async throws -> URL? {
            try? FileManager.default.removeItem(at: expected)
            let args = arguments(input: input, convertTo: filter, outputDirectory: outputDirectory, profile: profileDirectory(), infilter: infilter)
            try await withTimeout(seconds: timeoutSeconds) {
                _ = try await ctx.runProcess(soffice, args, allowNonZeroExit: true)
            }
            try ctx.checkCancelled()
            if FileManager.default.fileExists(atPath: expected.path) { return expected }
            // LibreOffice may normalise the name; accept the only new file with the right extension.
            let produced = ((try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == ext && !$0.lastPathComponent.hasPrefix(".") }
            return produced.count == 1 ? produced[0] : nil
        }
        if let ok = try await attempt() { return ok }
        // A crashed earlier instance can leave a locked or damaged profile: it is ours, start it afresh once.
        let profile = profileDirectory()
        if profile.lastPathComponent == "lo-profile" {
            try? FileManager.default.removeItem(at: profile)
            if let ok = try await attempt() { return ok }
        }
        throw ConversionError.message(failureMessage)
    }

    /// Runs `body`; throws a calm message when it takes longer than `seconds` (the process is killed because the body's task is cancelled).
    static func withTimeout(seconds: Double, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let timedOut = Locked(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                timedOut.value = true
                throw CancellationError()
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                if timedOut.value && !Task.isCancelled {
                    throw ConversionError.message(L10n("LibreOffice did not finish in time and was stopped.", "LibreOffice не завершил работу вовремя и был остановлен."))
                }
                throw error
            }
        }
    }
}
