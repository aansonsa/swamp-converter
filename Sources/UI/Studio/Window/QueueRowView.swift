import SwiftUI
import AppKit

/// One queue row: the shared `JobRowView` of the jobs module (kind icon, name, target, progress, ETA, size, status) plus the Studio's own marks for a waiting job: held ("Queued")
/// and edited ("Own settings"). Errors sit in the row's own status text, beside their cause.
struct QueueRowView: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            JobRowView(job: job)
            if job.state == .waiting {
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    if job.held { InfoChip(L("Queued", "В очереди"), symbol: "tray.full") }
                    if !job.overrides.isEmpty { InfoChip(L("Own settings", "Свои настройки"), symbol: "slider.horizontal.3", emphasized: true) }
                }
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .accessibilityElement(children: .contain)
    }
}

/// The menu of a selection of rows. One row gets the full menu; several get the bulk menu.
struct QueueRowMenu: View {
    @ObservedObject var model: QueuePanelModel
    var ids: Set<UUID>

    var body: some View {
        let jobs = model.jobs(for: ids)
        if jobs.count == 1, let job = jobs.first {
            single(job)
        } else if !jobs.isEmpty {
            bulk(jobs)
        }
    }

    // MARK: One row

    @ViewBuilder private func single(_ job: Job) -> some View {
        if job.state == .done, !job.outputs.isEmpty {
            Button(L("Show in Finder", "Показать в Finder")) { model.reveal(job) }
            Button(L("Open", "Открыть")) { model.open(job) }
        }
        if job.state == .waiting {
            Button(L("Edit Options", "Изменить параметры")) { model.editOptions(job) }
        }
        let targets = model.otherTargets(for: job)
        if !targets.isEmpty {
            Menu(L("Convert Again As", "Преобразовать ещё раз в")) {
                ForEach(targets) { t in Button { model.convertAgain(job, target: t.id) } label: { Label(t.title.text, systemImage: t.symbol) } }
            }
        }
        let presets = model.presets(for: job)
        if !presets.isEmpty {
            Menu(L("Duplicate with Another Preset", "Копия с другим шаблоном")) {
                ForEach(presets) { p in Button { model.duplicate(job, with: p) } label: { Label(p.name.text, systemImage: p.symbol) } }
            }
        }
        Divider()
        switch job.state {
        case .failed, .cancelled, .skipped:
            Button(job.state == .failed && job.errorMessage != nil ? L("Retry (\(Self.firstLine(job.errorMessage ?? "")))", "Повторить (\(Self.firstLine(job.errorMessage ?? "")))") : L("Retry", "Повторить")) {
                model.retry(ids: [job.id])
            }
        case .waiting:
            if job.held { Button(L("Start This One", "Запустить эту")) { model.runner.start(job) } }
            Button(L("Skip", "Пропустить")) { model.skip(ids: [job.id]) }
        case .running:
            Button(L("Pause", "Приостановить")) { model.pause(ids: [job.id]) }
        case .paused:
            Button(L("Resume", "Продолжить")) { model.resume(ids: [job.id]) }
        case .done: EmptyView()
        }
        Button(L("Remove", "Убрать"), role: .destructive) { model.remove(ids: [job.id]) }
        Divider()
        Button(L("Show Log", "Показать журнал")) { model.logJob = job }
        if !job.items.isEmpty { Button(L("Copy Command", "Скопировать команду")) { model.copyCommand(job) } }
    }

    // MARK: Several rows

    @ViewBuilder private func bulk(_ jobs: [Job]) -> some View {
        if model.canEditTogether(ids) {
            Button(L("Edit Selected…", "Изменить выбранные…")) { model.selection = ids; model.bulkEditing = true }
            Divider()
        }
        if jobs.contains(where: { $0.state == .failed || $0.state == .cancelled }) {
            Button(L("Retry", "Повторить")) { model.retry(ids: ids) }
        }
        if jobs.contains(where: { $0.state == .waiting }) {
            Button(L("Skip", "Пропустить")) { model.skip(ids: ids) }
        }
        Button(L("Remove", "Убрать"), role: .destructive) { model.remove(ids: ids) }
    }

    static func firstLine(_ s: String) -> String { s.split(separator: "\n").first.map { String($0.prefix(60)) } ?? s }
}
