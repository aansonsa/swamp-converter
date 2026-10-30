import SwiftUI
import AppKit

/// What the buttons of a job row do. One place, so the row, the HUD card, the context menu and the tests agree.
@MainActor
enum JobRowActions {
    enum Action: Equatable, CaseIterable { case cancel, pause, resume, retry, remove, reveal, open, quickLook, copyPath, copyError }

    static func perform(_ action: Action, job: Job, runner: JobRunner) {
        switch action {
        case .cancel: runner.cancel(job)
        case .pause: runner.pause(job)
        case .resume: runner.resume(job)
        case .retry: runner.retry(job)
        case .remove: runner.remove(job)
        case .reveal: ResultActions.reveal(job.outputs)
        case .open: ResultActions.open(job.outputs.count == 1 ? job.outputs : Array(job.outputs.prefix(1)))
        case .quickLook: ResultActions.quickLook(job.outputs)
        case .copyPath:
            if ResultActions.copyPaths(job.outputs) {
                MessageCenter.shared.post(job.outputs.count > 1 ? L("Paths copied", "Пути скопированы") : L("Path copied", "Путь скопирован"), symbol: "doc.on.doc")
            }
        case .copyError:
            let text = job.errorMessage ?? job.statusText
            if !text.isEmpty, ActionPasteboard.writeText(text) { MessageCenter.shared.post(L("Error text copied", "Текст ошибки скопирован"), symbol: "doc.on.doc") }
        }
    }

    static func title(_ action: Action) -> String {
        switch action {
        case .cancel: return L("Cancel", "Отменить")
        case .pause: return L("Pause", "Приостановить")
        case .resume: return L("Resume", "Продолжить")
        case .retry: return L("Retry", "Повторить")
        case .remove: return L("Remove from List", "Убрать из списка")
        case .reveal: return L("Show in Finder", "Показать в Finder")
        case .open: return L("Open", "Открыть")
        case .quickLook: return L("Quick Look", "Быстрый просмотр")
        case .copyPath: return L("Copy Path", "Скопировать путь")
        case .copyError: return L("Copy Error", "Скопировать текст ошибки")
        }
    }
}

/// One queue row, shared by the Jobs window, the Studio queue panel and the HUD card's siblings. Observes a `Job` through a throttled snapshot (see `JobRowObserver`).
///
///     icon | title                                   [pause] [cancel]
///          | file name                               or [reveal] [open] [share] [quick look] [copy path] [x]
///          | Downloading 62% > Converting
///          | ======== slanted bar ========
///          | 42%  About 2 minutes left  12 MB/s
///          | (finished) [photo.jpg]  <- drag it into any app
struct JobRowView: View {
    private let job: Job
    private let runner: JobRunner
    private let showsControls: Bool
    @StateObject private var observer: JobRowObserver

    init(job: Job, runner: JobRunner? = nil, showsControls: Bool = true) {
        let r = runner ?? JobRunner.shared
        self.job = job
        self.runner = r
        self.showsControls = showsControls
        _observer = StateObject(wrappedValue: JobRowObserver(job: job, runner: r))
    }

    var body: some View {
        let m = JobRowModel.make(observer.snapshot)
        HStack(alignment: .top, spacing: DS.Space.md) {
            JobIconTile(symbol: m.symbol, kind: m.statusKind, showsBadge: [.done, .doneWithWarnings, .failed, .paused].contains(m.phase))
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if !m.inputLine.isEmpty {
                            Text(m.inputLine).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: DS.Space.sm)
                    if showsControls { JobRowControls(model: m, job: job, runner: runner) }
                }
                JobRowBody(model: m)
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(m.accessibilityLabel))
        .jobRowAccessibilityActions(m, job: job, runner: runner)
    }
}

/// Everything under the title: stage chain, bar and numbers, state line, error text and result chips.
struct JobRowBody: View {
    var model: JobRowModel
    /// The HUD card shows buttons instead of the draggable chips.
    var showsChips = true

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if !m.stages.isEmpty { JobStageChain(segments: m.stages) }
            if !m.statusLine.isEmpty { statusText(m) }
            if m.showsBar {
                SlantedProgressBar(value: m.progress, secondary: m.barIsSecondary, height: 6)
                if m.percentText != nil || m.etaText != nil || m.speedText != nil {
                    HStack(spacing: DS.Space.sm) {
                        if let p = m.percentText { Text(p) }
                        if let e = m.etaText { Text(e) }
                        if let s = m.speedText { Text(s) }
                    }
                    .font(DS.Typo.numeric(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            if let err = m.errorText {
                Text(err).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if showsChips, m.hasResult {
                // A plain HStack: the chips shrink (their names truncate in the middle) instead of wrapping, which keeps the row height stable inside a List.
                HStack(spacing: DS.Space.xs + 2) {
                    ForEach(Array(m.outputs.prefix(2)), id: \.self) { OutputChip(url: $0) }
                    moreChip(m.outputs.count - 2)
                    Spacer(minLength: 0)
                }
                .padding(.top, DS.Space.xxs)
            }
        }
    }

    @ViewBuilder private func moreChip(_ extra: Int) -> some View {
        if extra > 0 { InfoChip(L("+\(extra) more", "ещё \(extra)")) }
    }

    @ViewBuilder private func statusText(_ m: JobRowModel) -> some View {
        let text = Text(m.statusLine).font(DS.Typo.caption).lineLimit(2)
        switch m.phase {
        case .failed: text.foregroundStyle(StatusTone.error.ink)
        case .doneWithWarnings: text.foregroundStyle(StatusTone.warning.ink)
        default: text.foregroundStyle(.secondary)
        }
    }
}

/// The buttons at the right of the title line. Which ones appear follows the row's phase.
struct JobRowControls: View {
    var model: JobRowModel
    var job: Job
    var runner: JobRunner
    @State private var shareAnchor: NSView?

    var body: some View {
        let m = model
        HStack(spacing: DS.Space.xxs) {
            if m.canRetry {
                Button { JobRowActions.perform(.retry, job: job, runner: runner) } label: {
                    Label(JobRowActions.title(.retry), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small).tint(nil)
            }
            if m.hasResult {
                button(.reveal, "magnifyingglass.circle")
                if m.outputs.count == 1 { button(.open, "arrow.up.forward.app") }
                JobIconButton(symbol: "square.and.arrow.up", label: L("Share", "Поделиться")) { share(m) }
                    .background(ViewAnchor { shareAnchor = $0 })
                button(.quickLook, "eye")
                button(.copyPath, "doc.on.doc")
            }
            if m.phase == .failed { button(.copyError, "doc.on.clipboard") }
            if m.canResume { button(.resume, "play.fill") }
            if m.canPause { button(.pause, "pause.fill") }
            if m.canCancel { button(.cancel, "xmark.circle.fill") }
            if m.canRemove { button(.remove, "xmark") }
        }
    }

    private func button(_ action: JobRowActions.Action, _ symbol: String) -> some View {
        JobIconButton(symbol: symbol, label: JobRowActions.title(action)) { JobRowActions.perform(action, job: job, runner: runner) }
    }

    private func share(_ m: JobRowModel) {
        ResultActions.share(m.outputs, from: shareAnchor, anchor: shareAnchor?.bounds ?? .zero)
    }
}

extension View {
    /// VoiceOver's rotor actions: the same things the buttons do.
    func jobRowAccessibilityActions(_ m: JobRowModel, job: Job, runner: JobRunner) -> some View {
        self
            .accessibilityAction(named: Text(JobRowActions.title(.cancel))) { if m.canCancel { JobRowActions.perform(.cancel, job: job, runner: runner) } }
            .accessibilityAction(named: Text(JobRowActions.title(.retry))) { if m.canRetry { JobRowActions.perform(.retry, job: job, runner: runner) } }
            .accessibilityAction(named: Text(JobRowActions.title(.reveal))) { if m.hasResult { JobRowActions.perform(.reveal, job: job, runner: runner) } }
            .accessibilityAction(named: Text(JobRowActions.title(.remove))) { if m.canRemove { JobRowActions.perform(.remove, job: job, runner: runner) } }
    }
}
