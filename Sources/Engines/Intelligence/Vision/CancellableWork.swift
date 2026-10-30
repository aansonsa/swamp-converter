import Foundation

/// A value that crosses an isolation boundary on the caller's word (the work is done on one queue and handed over once).
struct UncheckedBox<T>: @unchecked Sendable { var value: T }

/// Runs blocking work (a decode, a Vision request, a Core Image render) on a background queue and returns to the caller as soon as the task is cancelled, not when the
/// work ends: the person's Cancel must be felt within 200 ms even when a native call cannot be interrupted. The orphaned work finishes quietly and its result is
/// dropped, so it must be PURE (memory only): never let it write files.
enum CancellableWork {
    static func run<T>(qos: DispatchQoS.QoSClass = .userInitiated, onCancel: (() -> Void)? = nil, _ work: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let gate = ResultGate<T>()
        let job = UncheckedBox(value: work)
        let hook = UncheckedBox(value: onCancel)
        let boxed: UncheckedBox<T> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<UncheckedBox<T>, Error>) in
                gate.install(c)
                DispatchQueue.global(qos: qos).async { gate.finish(Result { UncheckedBox(value: try job.value()) }) }
            }
        } onCancel: {
            hook.value?()
            gate.finish(.failure(CancellationError()))
        }
        return boxed.value
    }
}

/// Delivers exactly one result to the continuation, whichever of "work done" and "cancelled" comes first (in either order relative to `install`).
final class ResultGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UncheckedBox<T>, Error>?
    private var pending: Result<UncheckedBox<T>, Error>?
    private var delivered = false

    func install(_ c: CheckedContinuation<UncheckedBox<T>, Error>) {
        lock.lock()
        if let r = pending, !delivered { delivered = true; lock.unlock(); c.resume(with: r); return }
        continuation = c
        lock.unlock()
    }

    func finish(_ r: Result<UncheckedBox<T>, Error>) {
        lock.lock()
        if delivered || pending != nil { lock.unlock(); return }
        if let c = continuation { delivered = true; continuation = nil; lock.unlock(); c.resume(with: r); return }
        pending = r
        lock.unlock()
    }
}
