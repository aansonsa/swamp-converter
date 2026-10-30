import SwiftUI
import AppKit

/// The embedded queue panel: rows from `JobRunner.shared.jobs` as `JobRowView`, drag to reorder, multi-select edits (Mixed values), row menu (Reveal, Open, Convert Again As..., Edit Options,
/// Duplicate with different preset, Retry, Skip, Remove, Show Log, Copy Command), controls Start Queue / Pause / Stop, "When done: nothing / reveal / notify / sleep".
struct QueuePanel: View {
    private let runner: JobRunner
    private let host: StudioWindowModel?

    /// A panel over any runner (the shared one by default).
    init(runner: JobRunner? = nil) { self.runner = runner ?? JobRunner.shared; host = nil }
    /// The panel of a Studio window: Start Queue applies "When done", Edit Options loads the job into the window's session.
    init(model: StudioWindowModel) { runner = model.runner; host = model }

    var body: some View { QueuePanelContent(runner: runner, host: host) }
}

struct QueuePanelContent: View {
    @ObservedObject var runner: JobRunner
    var host: StudioWindowModel?
    @StateObject private var model: QueuePanelModel

    init(runner: JobRunner, host: StudioWindowModel?) {
        self.runner = runner; self.host = host
        _model = StateObject(wrappedValue: QueuePanelModel(runner: runner, host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            QueueHeader(model: model, runner: runner, host: host)
            Divider()
            if runner.jobs.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: L("The queue is empty", "Очередь пуста"),
                               message: L("Choose “Add to Queue” to line up several conversions, then start them together.", "Нажмите «В очередь», чтобы выстроить несколько преобразований, и запустите их вместе."))
            } else {
                list
            }
            QueueFooter(model: model, runner: runner)
        }
        .sheet(item: $model.logJob) { job in QueueLogSheet(job: job) }
        .sheet(isPresented: $model.bulkEditing) { QueueBulkEditSheet(model: model, ids: model.selection) }
        .confirmationDialog(L("Stop the queue?", "Остановить очередь?"), isPresented: $model.confirmStop, titleVisibility: .visible) {
            Button(L("Stop and Discard the Running Work", "Остановить и отбросить выполняемое"), role: .destructive) { model.stop() }
            Button(L("Keep Going", "Продолжить"), role: .cancel) { }
        } message: {
            Text(L("Running conversions are canceled. Waiting ones stay in the queue.", "Выполняемые преобразования будут отменены. Ожидающие останутся в очереди."))
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(runner.jobs) { job in
                QueueRowView(job: job)
                    .tag(job.id)
                    .moveDisabled(job.state != .waiting)
                    .listRowSeparator(.visible)
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            QueueRowMenu(model: model, ids: ids)
        } primaryAction: { ids in
            guard ids.count == 1, let job = model.jobs(for: ids).first else { return }
            switch job.state {
            case .waiting: model.editOptions(job)
            case .done where !job.outputs.isEmpty: model.reveal(job)
            default: model.logJob = job
            }
        }
        .onDeleteCommand { model.remove(ids: model.selection) }
        .accessibilityLabel(Text(L("Queue", "Очередь")))
    }
}

// MARK: - Header and footer

struct QueueHeader: View {
    @ObservedObject var model: QueuePanelModel
    @ObservedObject var runner: JobRunner
    var host: StudioWindowModel?

    var body: some View {
        let snap = QueueSnapshot.make(runner)
        StudioWrapLayout(spacing: DS.Space.md, lineSpacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Queue", "Очередь")).font(DS.Typo.headline)
                Text(QueueSummaryText.counts(snap)).font(DS.Typo.caption).foregroundStyle(.secondary)
            }
            // While the queue is paused the Pause button turns into Resume; Start keeps its own name so the two never read the same.
            Button { model.startOrResume() } label: { Label(L("Start Queue", "Запустить очередь"), systemImage: "play.fill") }
                .secondaryButtonLook()
                .disabled(snap.held == 0 && !snap.queuePaused && snap.waiting == 0)
            Button { model.pauseOrResume() } label: { Label(snap.queuePaused ? L("Resume", "Продолжить") : L("Pause", "Пауза"), systemImage: snap.queuePaused ? "play" : "pause.fill") }
                .secondaryButtonLook()
                .disabled(snap.running + snap.paused == 0 && !snap.queuePaused)
            Button { model.requestStop() } label: { Label(L("Stop", "Стоп"), systemImage: "stop.fill") }
                .secondaryButtonLook()
                .disabled(snap.running + snap.paused + snap.waiting + snap.held == 0)
            if model.canEditTogether(model.selection) {
                Button { model.bulkEditing = true } label: { Label(L("Edit Selected…", "Изменить выбранные…"), systemImage: "slider.horizontal.3") }
                    .secondaryButtonLook()
            }
            if let host { QueueWhenDonePicker(host: host) }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QueueWhenDonePicker: View {
    @ObservedObject var host: StudioWindowModel

    var body: some View {
        Picker(selection: $host.whenDone) {
            ForEach(QueueWhenDone.allCases) { w in Label(w.title.text, systemImage: w.symbol).tag(w) }
        } label: {
            Text(L("When done", "По окончании"))
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(Text(L("When done", "По окончании")))
    }
}

struct QueueFooter: View {
    @ObservedObject var model: QueuePanelModel
    @ObservedObject var runner: JobRunner

    var body: some View {
        let snap = QueueSnapshot.make(runner)
        let reasons = runner.jobs.filter { $0.state == .failed }.compactMap(\.errorMessage)
        let summary = QueueSummaryText.failureSummary(failed: snap.failed, total: snap.total, reasons: reasons)
        VStack(spacing: 0) {
            if !model.lastRemoved.isEmpty {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "trash").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(model.lastRemoved.count == 1 ? L("Removed “\(model.lastRemoved[0].title)”", "Убрано: «\(model.lastRemoved[0].title)»") : L("Removed \(model.lastRemoved.count) items", "Убрано элементов: \(model.lastRemoved.count)"))
                        .font(DS.Typo.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button(L("Undo", "Отменить")) { model.undoRemove() }.buttonStyle(.bordered).controlSize(.small)
                    Button { model.dismissUndo() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(Text(SharedStrings.dismiss.text))
                }
                .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
                Divider()
            }
            if summary != nil || snap.done + snap.failed > 0 {
                HStack(spacing: DS.Space.md) {
                    if let summary {
                        Label(summary, systemImage: "exclamationmark.triangle").font(DS.Typo.callout).fixedSize(horizontal: false, vertical: true)
                        Button(L("Retry Failed", "Повторить неудавшиеся")) { model.retryFailed() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if snap.done + snap.failed > 0 { Button(L("Clear Finished", "Убрать завершённые")) { model.clearFinished() }.buttonStyle(.bordered).controlSize(.small) }
                }
                .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
            }
        }
        .tint(nil)
    }
}

// MARK: - Log

struct QueueLogSheet: View {
    @ObservedObject var job: Job
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(job.title).font(DS.Typo.headline).lineLimit(2)
            ScrollView {
                Text(job.logText.isEmpty ? L("Nothing has been logged yet.", "В журнал пока ничего не записано.") : job.logText)
                    .font(DS.Typo.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.Space.sm)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            HStack {
                Button(L("Copy", "Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.logText, forType: .string)
                }
                .secondaryButtonLook()
                Spacer()
                Button(SharedStrings.close.text) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 520, minHeight: 360)
        .appRoot()
    }
}
