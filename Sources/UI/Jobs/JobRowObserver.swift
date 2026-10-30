import SwiftUI
import Combine

/// Turns a `Job` into the stream of `JobSnapshot`s a row (or the HUD card) draws, at most 10 times a second.
///
/// A `Job` publishes every change of every property, and its log grows with every line a tool prints (ffmpeg prints hundreds). A view that observed the job itself
/// would rebuild for each of them. This observer listens to the properties the row shows (not the log), re-reads the job AFTER the change landed (a `@Published`
/// emits before its value is stored), and publishes a snapshot at most every 100 ms. Combine's `throttle` arms a one-shot only while changes flow: nothing runs when the job is quiet.
@MainActor
final class JobRowObserver: ObservableObject {
    @Published private(set) var snapshot: JobSnapshot
    private let job: Job
    private let runner: JobRunner
    private let symbol: String?
    private var bag = Set<AnyCancellable>()

    init(job: Job, runner: JobRunner? = nil, registry: OperationRegistry = .shared) {
        let runner = runner ?? JobRunner.shared
        self.job = job
        self.runner = runner
        let symbol = JobSnapshot.symbol(for: job, registry: registry)
        self.symbol = symbol
        snapshot = JobSnapshot(job: job, queuePaused: runner.queuePaused, operationSymbol: symbol)

        let changes: [AnyPublisher<Void, Never>] = [
            job.$state.map { _ in }.eraseToAnyPublisher(),
            job.$progress.map { _ in }.eraseToAnyPublisher(),
            job.$statusText.map { _ in }.eraseToAnyPublisher(),
            job.$eta.map { _ in }.eraseToAnyPublisher(),
            job.$stages.map { _ in }.eraseToAnyPublisher(),
            job.$outputs.map { _ in }.eraseToAnyPublisher(),
            job.$errorMessage.map { _ in }.eraseToAnyPublisher(),
            job.$failures.map { _ in }.eraseToAnyPublisher(),
            job.$held.map { _ in }.eraseToAnyPublisher(),
            job.$cancelRequested.map { _ in }.eraseToAnyPublisher(),
            job.$title.map { _ in }.eraseToAnyPublisher(),
            job.$note.map { _ in }.eraseToAnyPublisher(),
            runner.$queuePaused.map { _ in }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .dropFirst(changes.count)               // every @Published replays its current value on subscription
            .receive(on: RunLoop.main)              // after the new value is stored
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
    }

    func refresh() {
        let next = JobSnapshot(job: job, queuePaused: runner.queuePaused, operationSymbol: symbol)
        if next != snapshot { snapshot = next }
    }
}
