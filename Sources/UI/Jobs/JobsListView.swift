import SwiftUI
import AppKit

/// The content of the Jobs window: Running, Queued and Finished sections of `JobRowView`s, an empty state with the wordmark, a toolbar (pause / resume the queue, clear finished),
/// drag to reorder waiting rows, a context menu with the result actions, and a log sheet.
struct JobsListView: View {
    @ObservedObject var model: JobsListModel
    @ObservedObject var runner: JobRunner
    /// Snapshots render the content without a window toolbar: the same buttons then sit in a strip at the top.
    var inlineToolbar = false

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            if inlineToolbar {
                HStack { Spacer(); JobsToolbarButtons(model: model, runner: runner, titled: true) }
                    .padding(.horizontal, DS.Space.gutter).padding(.vertical, DS.Space.sm)
                Divider()
            }
            if model.isEmpty { emptyState } else { list }
        }
        .toolbar { if !inlineToolbar { ToolbarItemGroup(placement: .primaryAction) { JobsToolbarButtons(model: model, runner: runner, titled: false) } } }
        .sheet(item: $model.logJob) { JobLogView(job: $0) }
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "tray", title: L("No jobs", "Задач нет"),
                       message: L("Drag files and the wheel opens, or drop them on the menu-bar icon. Running and finished jobs appear here.",
                                  "Перетащите файлы на значок в строке меню или вызовите круговое меню над файлом. Здесь появятся текущие и завершённые задачи."),
                       showsWordmark: true)
    }

    private var list: some View {
        let running = model.running, queued = model.queued, finished = model.finished
        return List {
            if !running.isEmpty {
                Section { rows(running) } header: { JobsSectionHeader(title: L("Running", "Выполняются"), count: running.count) }
            }
            if !queued.isEmpty {
                Section {
                    ForEach(queued) { job in row(job) }.onMove { model.moveQueued(from: $0, to: $1) }
                } header: { JobsSectionHeader(title: L("Queued", "В очереди"), count: queued.count) }
            }
            if !finished.isEmpty {
                Section { rows(finished) } header: { JobsSectionHeader(title: L("Finished", "Завершены"), count: finished.count) }
            }
        }
        .listStyle(.inset)
    }

    private func rows(_ jobs: [Job]) -> some View { ForEach(jobs) { row($0) } }

    private func row(_ job: Job) -> some View {
        JobRowView(job: job, runner: runner)
            .id(job.id)
            .listRowInsets(EdgeInsets(top: DS.Space.sm, leading: DS.Space.lg, bottom: DS.Space.sm, trailing: DS.Space.md))
            .contextMenu { JobsRowMenu(job: job, runner: runner, model: model) }
    }
}

struct JobsSectionHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .font(DS.Typo.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Pause / resume the queue and clear the finished rows.
struct JobsToolbarButtons: View {
    @ObservedObject var model: JobsListModel
    @ObservedObject var runner: JobRunner
    var titled: Bool

    var body: some View {
        let _ = model.revision
        Group {
            if titled { buttons.labelStyle(.titleAndIcon) } else { buttons.labelStyle(.iconOnly) }
        }
        .buttonStyle(.bordered).controlSize(.small).tint(nil)
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.sm) {
            Button { model.toggleQueuePause() } label: {
                Label(runner.queuePaused ? L("Resume Queue", "Продолжить очередь") : L("Pause Queue", "Приостановить очередь"),
                      systemImage: runner.queuePaused ? "play.fill" : "pause.fill")
            }
            .disabled(!runner.queuePaused && !model.hasWork)
            .help(runner.queuePaused ? L("Start jobs again", "Снова запускать задачи") : L("Pause running jobs and hold the waiting ones", "Приостановить текущие задачи и удержать ожидающие"))
            Button { model.clearFinished() } label: {
                Label(L("Clear Finished", "Убрать завершённые"), systemImage: "eraser")
            }
            .disabled(!model.canClearFinished)
            .help(L("Remove finished jobs from the list (the files stay)", "Убрать завершённые задачи из списка (файлы остаются)"))
        }
    }
}

/// The right-click menu of a row.
struct JobsRowMenu: View {
    var job: Job
    var runner: JobRunner
    @ObservedObject var model: JobsListModel

    var body: some View {
        let finishedOK = job.state == .done && !job.outputs.isEmpty
        if finishedOK {
            item(.reveal, "magnifyingglass.circle")
            if job.outputs.count == 1 { item(.open, "arrow.up.forward.app") }
            item(.quickLook, "eye")
            item(.copyPath, "doc.on.doc")
            Divider()
        }
        if job.state == .failed || job.state == .cancelled || job.state == .skipped { item(.retry, "arrow.clockwise") }
        if job.state == .running { item(.pause, "pause.fill") }
        if job.state == .paused { item(.resume, "play.fill") }
        if !job.state.isFinished { item(.cancel, "xmark.circle") }
        if job.state.isFinished { item(.remove, "xmark") }
        Divider()
        Button { model.logJob = job } label: { Label(L("Show Log", "Показать журнал"), systemImage: "text.alignleft") }
    }

    private func item(_ action: JobRowActions.Action, _ symbol: String) -> some View {
        Button { JobRowActions.perform(action, job: job, runner: runner) } label: { Label(JobRowActions.title(action), systemImage: symbol) }
    }
}

/// The text log of one job (what the tools printed), selectable and copyable.
struct JobLogView: View {
    @ObservedObject var job: Job
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(job.title).font(DS.Typo.headline).lineLimit(1)
            ScrollView {
                Text(job.logText.isEmpty ? L("Nothing was logged.", "В журнал ничего не записано.") : job.logText)
                    .font(DS.Typo.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.md)
            }
            .background(DS.Surface.control, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            HStack {
                Button(L("Copy", "Скопировать")) { _ = ActionPasteboard.writeText(job.logText) }.disabled(job.logText.isEmpty)
                Spacer()
                Button(SharedStrings.close.text) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.bordered).tint(nil)
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 480, minHeight: 320)
    }
}
