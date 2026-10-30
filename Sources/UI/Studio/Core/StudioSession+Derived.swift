import Foundation
import CoreGraphics

// Estimate, summary chips and preview: computed OFF the main thread, keyed by an options hash, cancellable. Part of StudioSession.
//
//  * Every edit cancels the running work and starts again; a result is published only when its key still equals the current one, so a slow answer for old
//    options can never overwrite a new one.
//  * Estimate and chips are cheap by contract (`Operation.estimate` / `summaryChips`) and start at once. The preview may be expensive: after an edit it waits 250 ms
//    (a sleep inside the task, not a timer) so a slider drag does not run an encode per tick.
//  * Nothing here runs while nothing changes.

/// Identity of "these options on these sources with this operation": the key under which derived results are valid.
struct StudioDerivedKey: Hashable {
    var operationID: String
    var sourceIDs: [String]
    var values: [String: OptionValue]
}

struct StudioPreviewKey: Hashable {
    var base: StudioDerivedKey
    var time: Double?
    var maxPixel: Int
}

/// Runs `body` on a background task and propagates cancellation of the caller into it.
func studioRunDetached<T: Sendable>(priority: TaskPriority = .userInitiated, _ body: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority) { await body() }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}

extension StudioSession {
    var currentDerivedKey: StudioDerivedKey? {
        guard let op = operation, let r = resolved else { return nil }
        return StudioDerivedKey(operationID: op.meta.id, sourceIDs: sources.filter(\.isUsable).map(\.id), values: r.values.storage)
    }

    /// The preview shown matches the current options.
    var isPreviewCurrent: Bool {
        guard preview != nil, let k = previewKey, let cur = currentDerivedKey else { return false }
        return k.base == cur
    }

    func scheduleDerived(previewToo: Bool) {
        derivedTask?.cancel()
        guard let op = operation, let res = resolved, let key = currentDerivedKey else {
            estimate = nil; summaryChips = []
            return
        }
        derivedKey = key
        let files = activeFiles, links = activeLinks
        let info = activeSource?.info
        let values = res.values
        derivedTask = Task { [weak self] in
            let out = await studioRunDetached { () -> (OperationEstimate?, [String]) in
                if Task.isCancelled { return (nil, []) }
                let est = files.isEmpty ? op.estimateLinks(options: values, links: links) : op.estimate(options: values, items: files, source: info)
                if Task.isCancelled { return (nil, []) }
                return (est, op.summaryChips(options: values, source: info))
            }
            guard !Task.isCancelled, let self, self.derivedKey == key else { return }
            self.estimate = out.0
            self.summaryChips = out.1
        }
        if previewToo, previewRequest != nil { startPreview(debounceNanoseconds: 250_000_000) }
    }

    /// Requests a preview at `time` (video frame / audio position; nil for images and documents). Cancels the previous request; result keyed by the options hash.
    func requestPreview(time: Double?, maxPixel: Int) {
        previewRequest = (time, maxPixel)
        startPreview(debounceNanoseconds: 0)
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequest = nil
        isPreviewing = false
    }

    func startPreview(debounceNanoseconds: UInt64) {
        previewTask?.cancel()
        guard let op = operation, let res = resolved, let base = currentDerivedKey, let request = previewRequest else {
            isPreviewing = false
            return
        }
        let key = StudioPreviewKey(base: base, time: request.time, maxPixel: request.maxPixel)
        let files = activeFiles
        let info = activeSource?.info
        let values = res.values
        isPreviewing = true
        previewTask = Task { [weak self] in
            if debounceNanoseconds > 0 { try? await Task.sleep(nanoseconds: debounceNanoseconds) }
            if Task.isCancelled { return }
            let result: OperationPreview? = await studioRunDetached { () -> OperationPreview? in
                guard !files.isEmpty else { return nil }
                return try? await op.preview(items: files, options: values, source: info, time: request.time, maxPixel: request.maxPixel)
            }
            // A cancelled or superseded request publishes nothing and leaves `isPreviewing` to the request that replaced it.
            guard !Task.isCancelled, let self, self.currentDerivedKey == key.base,
                  self.previewRequest?.time == request.time, self.previewRequest?.maxPixel == request.maxPixel else { return }
            self.preview = result
            self.previewKey = key
            self.isPreviewing = false
        }
    }

    /// "Measure": asks the operation for a real sample result (a preview with `sampleOutputBytes`) and turns it into a measured estimate. Operations that cannot
    /// measure answer with a calm note instead.
    func measure() {
        guard operation != nil else { return }
        measureNote = nil
        let before = estimate
        if previewRequest == nil { previewRequest = (nil, 1024) }
        startPreview(debounceNanoseconds: 0)
        let task = previewTask
        Task { [weak self] in
            await task?.value
            guard let self else { return }
            if let bytes = self.preview?.sampleOutputBytes, self.isPreviewCurrent {
                var e = before ?? OperationEstimate()
                e.bytes = bytes
                e.confidence = .measured
                self.estimate = e
            } else if self.preview?.sampleOutputBytes == nil {
                self.measureNote = L10n("This format can’t be measured on a sample. The estimate stays approximate.",
                                        "Для этого формата замер на образце недоступен. Оценка остаётся приблизительной.")
            }
        }
    }

    /// Waits for the estimate / chips / preview work in flight (tests, scripted use).
    func settle() async {
        await derivedTask?.value
        await previewTask?.value
    }
}
