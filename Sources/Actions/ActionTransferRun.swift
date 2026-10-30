import Foundation

// Executes a TransferPlan. No questions are asked here: every decision is already in the plan, so the same code runs inline (small copies, toast only) and as a
// Jobs card (big ones). Safety rules, in the order they matter:
//   * Nothing is ever overwritten. New items are written under a hidden `.name.xxxxxxxx.part` name and renamed into place with an atomic, never-replacing rename.
//   * Replace sends the old item to the Trash (never unlinks it), and only after the new one is complete next to it.
//   * A move on the same volume is one rename. A move across volumes is copy, verify (it exists and has the same size and member count), and only then the
//     original goes to the Trash; if anything is off the original stays exactly where it was.
//   * Cancelling stops within one copy chunk and removes the partial item.

struct TransferOutcome: Sendable, Equatable {
    var outputs: [URL] = []
    /// "name: sentence" for items that failed, plus notices such as "copied, but the original could not be moved to the Trash".
    var failures: [String] = []
    /// Items whose original is still in place although the mode was Move (the copy exists next to the new location).
    var originalsKept = 0
}

struct TransferControl: Sendable {
    var isCancelled: @Sendable () -> Bool = { false }
    /// 0...1 over the whole plan.
    var progress: @Sendable (Double) -> Void = { _ in }
}

enum TransferRunner {
    /// Synchronous and blocking: call it off the main actor (`runAsync`). Throws `CancellationError`, or a calm `ConversionError.message` when nothing could be done.
    static func run(plan: TransferPlan, fs: TransferFS = .live, allowClone: Bool = true, control: TransferControl = TransferControl()) throws -> TransferOutcome {
        var outcome = TransferOutcome()
        let folder = plan.folderURL
        let totalWeight = Double(max(plan.steps.reduce(Int64(0)) { $0 + max($1.bytes, 1) }, 1))
        var doneWeight = 0.0
        let throttle = ProgressThrottle()
        var failureErrors: [Error] = []

        for step in plan.steps {
            if control.isCancelled() { throw CancellationError() }
            let weight = Double(max(step.bytes, 1))
            let before = doneWeight
            do {
                let result = try perform(step, mode: plan.mode, folder: folder, fs: fs, allowClone: allowClone) { bytes in
                    if control.isCancelled() { return false }
                    let fraction = (before + min(Double(bytes), weight)) / totalWeight
                    if throttle.shouldReport(fraction) { control.progress(min(fraction, 1)) }
                    return true
                }
                outcome.outputs.append(result.url)
                if let warning = result.warning {
                    outcome.failures.append(warning)
                    outcome.originalsKept += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let name = step.sourceURL.lastPathComponent
                let text = TransferErrors.describe(error, name: name, folder: folder.lastPathComponent)
                failureErrors.append(error)
                outcome.failures.append("\(name): \(text)")
            }
            doneWeight += weight
            control.progress(min(doneWeight / totalWeight, 1))
        }
        if outcome.outputs.isEmpty, !outcome.failures.isEmpty {
            // Single item or everything failed: no partial success to report, so it is an error with the plain sentences.
            if plan.steps.count == 1, let step = plan.steps.first, let error = failureErrors.first {
                throw ConversionError.message(L10n(TransferErrors.describe(error, name: step.sourceURL.lastPathComponent, folder: folder.lastPathComponent)))
            }
            throw ConversionError.aggregate(outcome.failures)
        }
        return outcome
    }

    /// Runs on a background thread; cancelling the calling task stops the copy within a chunk.
    static func runAsync(plan: TransferPlan, fs: TransferFS = .live, allowClone: Bool = true,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TransferOutcome {
        let cancelled = Locked(false)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try run(plan: plan, fs: fs, allowClone: allowClone, control: TransferControl(isCancelled: { cancelled.value }, progress: progress))
            }.value
        } onCancel: {
            cancelled.value = true
        }
    }

    // MARK: One step

    private struct StepResult {
        var url: URL
        var warning: String?
    }

    private static func perform(_ step: TransferStep, mode: TransferMode, folder: URL, fs: TransferFS, allowClone: Bool,
                                report: @escaping CopyEngine.Progress) throws -> StepResult {
        let src = step.sourceURL
        let name = src.lastPathComponent
        var final = step.destinationURL
        if step.kind != .replace, fs.exists(final) {
            // The name was free when the plan was made. Never overwrite: take the next free one.
            final = TransferNaming.uniqueURL(in: folder, name: name, isDirectory: step.isDirectory, exists: fs.exists)
        }
        guard fs.exists(src) else { throw CopyEngine.Failure.posix(ENOENT) }
        let crossVolume = mode == .move && !fs.sameVolume(src, folder)

        // Move on the same volume: one atomic rename.
        if mode == .move, !crossVolume {
            if step.kind == .replace, fs.exists(final) {
                let temp = TransferNaming.partURL(in: folder, for: name, isDirectory: step.isDirectory)
                try fs.rename(src, temp)
                do { try fs.trash(final) } catch {
                    try? fs.rename(temp, src)
                    throw ConversionError.message(oldItemNotTrashed(final.lastPathComponent))
                }
                do { try fs.rename(temp, final) } catch {
                    try? fs.rename(temp, src)
                    throw error
                }
            } else {
                try fs.rename(src, final)
            }
            _ = report(step.bytes)
            return StepResult(url: final, warning: nil)
        }

        // Copy (or the copy half of a cross-volume move): complete the new item under a hidden name first.
        let temp = TransferNaming.partURL(in: folder, for: name, isDirectory: step.isDirectory)
        try fs.copy(src, temp, allowClone, report)
        func discardTemp() { try? FileManager.default.removeItem(at: temp) }   // our own half-finished copy
        let want = fs.signature(src), have = fs.signature(temp)
        guard want.bytes == have.bytes, want.files == have.files else {
            discardTemp()
            throw ConversionError.message(L10n("“\(name)” changed while it was being copied. Nothing was replaced; try again.",
                                               "«\(name)» изменился во время копирования. Ничего не заменено, попробуйте ещё раз."))
        }
        if step.kind == .replace, fs.exists(final) {
            do { try fs.trash(final) } catch {
                discardTemp()
                throw ConversionError.message(oldItemNotTrashed(final.lastPathComponent))
            }
        }
        do { try fs.rename(temp, final) } catch {
            discardTemp()
            throw error
        }
        guard mode == .move else { return StepResult(url: final, warning: nil) }

        // Cross-volume move: the original goes to the Trash only now, and only because the copy is verified in place.
        let placed = fs.signature(final)
        guard fs.exists(final), placed.bytes == want.bytes, placed.files == want.files else {
            return StepResult(url: final, warning: L("\(name): the copy could not be verified, so the original was left where it is.",
                                                       "\(name): копию не удалось проверить, поэтому оригинал оставлен на месте."))
        }
        do { try fs.trash(src) } catch {
            return StepResult(url: final, warning: L("\(name): copied, but the original could not be moved to the Trash.",
                                                       "\(name): скопировано, но оригинал не удалось переместить в Корзину."))
        }
        return StepResult(url: final, warning: nil)
    }

    private static func oldItemNotTrashed(_ name: String) -> L10n {
        L10n("The existing “\(name)” could not be moved to the Trash, so it was not replaced.",
             "Существующий «\(name)» не удалось переместить в Корзину, поэтому он не заменён.")
    }
}

/// Reports at most every 50 ms and when the value moves by half a percent, so a long copy does not flood the main actor.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue = -1.0
    private var lastTime = 0.0

    func shouldReport(_ value: Double, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value >= 1 || (now - lastTime >= 0.05 && abs(value - lastValue) >= 0.005) else { return false }
        lastValue = value; lastTime = now
        return true
    }
}

/// "Will it fit?" before a single byte is written (essential for copies to a USB drive).
enum TransferSpace {
    /// Bytes the plan will really need on the destination volume: a move on the same volume needs none, a copy on one APFS volume is a clone and needs none.
    static func requiredBytes(_ plan: TransferPlan, fs: TransferFS, cloneable: (URL) -> Bool) -> Int64 {
        let folder = plan.folderURL
        var need: Int64 = 0
        for step in plan.steps {
            let same = fs.sameVolume(step.sourceURL, folder)
            if same, plan.mode == .move { continue }
            if same, cloneable(folder) { continue }
            need += step.bytes
        }
        return need
    }

    /// Throws a calm message when `required` exceeds `available`. A nil `available` (unknown) lets the copy try.
    static func check(required: Int64, available: Int64?, folderName: String) throws {
        guard required > 0, let available, required > available else { return }
        throw ConversionError.message(L10n(
            "There is not enough free space in “\(folderName)”: \(Util.formatBytes(required)) needed, \(Util.formatBytes(max(available, 0))) available.",
            "В «\(folderName)» недостаточно места: нужно \(Util.formatBytes(required)), свободно \(Util.formatBytes(max(available, 0)))."))
    }

    static func available(in folder: URL) -> Int64? {
        let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func supportsCloning(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }
}
