import Foundation
import SwiftUI

// The state behind every "Install yt-dlp" / "Update" button (the install offer sheet and Settings > Downloader share it). It only calls the explicit
// `YtDlpToolManager.install()` / `update()` of the downloader engine, which asks `NetworkGate`, verifies the SHA-256 checksum of the release and leaves no file
// behind when anything fails. Here: progress for the UI (<= 10 Hz), the checksum result in plain words, and the errors as calm sentences.

@MainActor
final class YtDlpInstallModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(kind: Kind, progress: Double)
        case succeeded(Outcome)
        case failed(String)
    }
    enum Kind: Equatable { case install, update }

    /// What a finished run tells. `checksumVerified` is true only after the engine compared the SHA-256 of the download with the release's checksum file.
    struct Outcome: Equatable {
        var kind: Kind
        var version: String?
        var checksumVerified: Bool
        var alreadyLatest: Bool
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private var lastProgressAt = Date.distantPast
    private let manager: YtDlpToolManager

    init(manager: YtDlpToolManager? = nil) { self.manager = manager ?? .shared }

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// The explicit install. The returned task is the same one `cancel()` stops; await `finished()` to wait for it.
    func install() { run(.install) }
    func update() { run(.update) }

    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { phase = .idle }
    }

    func reset() { if !isWorking { phase = .idle } }

    /// Waits for the running install/update (tests, the install offer sheet).
    func finished() async { await task?.value }

    private func run(_ kind: Kind) {
        guard !isWorking else { return }
        phase = .working(kind: kind, progress: 0)
        lastProgressAt = .distantPast
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome: Outcome
                switch kind {
                case .install:
                    try await self.manager.install { [weak self] value in self?.report(value) }
                    outcome = Outcome(kind: .install, version: await self.manager.installedVersion(), checksumVerified: true, alreadyLatest: false)
                case .update:
                    let result = try await self.manager.update { [weak self] value in self?.report(value) }
                    switch result {
                    case .alreadyLatest(let v): outcome = Outcome(kind: .update, version: v, checksumVerified: false, alreadyLatest: true)
                    case .updated(_, let to): outcome = Outcome(kind: .update, version: to, checksumVerified: true, alreadyLatest: false)
                    }
                }
                if Task.isCancelled { self.phase = .idle } else { self.phase = .succeeded(outcome) }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(Self.plain(error))
            }
        }
    }

    /// Called from the download's background thread; hops to the main actor and keeps the UI at 10 updates a second at most.
    private nonisolated func report(_ value: Double) {
        Task { @MainActor [weak self] in
            guard let self, case .working(let kind, _) = self.phase else { return }
            let now = Date()
            guard value >= 1 || now.timeIntervalSince(self.lastProgressAt) >= 0.1 else { return }
            self.lastProgressAt = now
            self.phase = .working(kind: kind, progress: Util.clamp(value, 0, 1))
        }
    }

    /// The error as one calm sentence (the engine already phrases its own; anything else gets a generic line).
    static func plain(_ error: Error) -> String {
        if error is URLError {
            return L("Could not reach github.com. Check the internet connection and try again.", "Не удалось связаться с github.com. Проверьте подключение к интернету и повторите.")
        }
        return ConversionError.describe(error)
    }

    // MARK: Words

    /// The line under the progress bar.
    static func progressText(kind: Kind, progress: Double) -> String {
        let percent = Int((Util.clamp(progress, 0, 1) * 100).rounded())
        if progress >= 0.9 && progress < 1 { return L("Checking the SHA-256 checksum…", "Проверка контрольной суммы SHA-256…") }
        switch kind {
        case .install: return L("Downloading yt-dlp… \(percent)%", "Загрузка yt-dlp… \(percent) %")
        case .update: return L("Updating yt-dlp… \(percent)%", "Обновление yt-dlp… \(percent) %")
        }
    }

    /// The success line, including the checksum result.
    static func successText(_ o: Outcome) -> String {
        let v = o.version.map { " \($0)" } ?? ""
        if o.alreadyLatest { return L("yt-dlp\(v) is up to date.", "yt-dlp\(v) — последняя версия.") }
        let verb = o.kind == .install ? L("Installed", "Установлено") : L("Updated", "Обновлено")
        return L("\(verb) yt-dlp\(v). The SHA-256 checksum matched the official release.", "\(verb) yt-dlp\(v). Контрольная сумма SHA-256 совпала с официальным релизом.")
    }
}
