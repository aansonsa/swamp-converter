import SwiftUI

// Offscreen snapshots of the jobs module: rows in every state, the window with six mixed rows, the empty state, toasts, the HUD cards.
// `./build.sh snapshot <dir> jobs`. The window's toolbar buttons are drawn as a strip at the top (the offscreen harness hosts a plain view, which has no toolbar).

/// A column of rows on the window background.
struct JobsRowsSheet: View {
    var jobs: [Job]
    var runner: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                JobRowView(job: job, runner: runner)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                if index < jobs.count - 1 { Divider().padding(.leading, DS.Space.lg) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appRoot()
    }
}

struct JobsToastSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            ToastBubble(item: ToastItem(text: L("Path copied", "Путь скопирован"), symbol: "doc.on.doc"))
            ToastBubble(item: ToastItem(text: L("The file is no longer where it was.", "Файла больше нет на прежнем месте."), symbol: "questionmark.folder", severity: .warning))
            ToastBubble(item: ToastItem(text: L("Could not finish: 2 failed. Open Swamp Converter for details.", "Не удалось завершить: 2 задачи. Подробности в окне задач."),
                                        severity: .error, action: (L("Show Jobs", "Показать задачи"), {})))
            ToastBubble(item: ToastItem(text: L("Done: 5 files ready", "Готово: 5 файлов"), symbol: "checkmark.circle", action: (L("Show in Finder", "Показать в Finder"), {})))
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appRoot()
    }
}

struct JobsHUDSheet: View {
    var jobs: [Job]
    var runner: JobRunner

    var body: some View {
        GlassGroup(spacing: DS.Space.sm) {
            VStack(spacing: DS.Space.sm) {
                ForEach(jobs) { JobHUDCard(job: $0, runner: runner, onClose: {}) }
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .appRoot()
    }
}

enum JobsSnapshots {
    @MainActor private static let runner = JobRunner(persistence: false)

    @MainActor
    static func register() {
        let s = SnapshotRegistry.shared
        let full = SnapshotVariant.lightDarkRu
        let a11y = SnapshotVariant.accessibility
        let r = runner

        s.register("jobs.row-running", size: CGSize(width: 540, height: 150), backdrop: .windowBackground, variants: full) {
            JobsRowsSheet(jobs: [JobsSamples.running()], runner: r)
        }
        s.register("jobs.row-two-stage", size: CGSize(width: 540, height: 170), backdrop: .windowBackground, variants: full) {
            JobsRowsSheet(jobs: [JobsSamples.twoStage()], runner: r)
        }
        s.register("jobs.row-finished", size: CGSize(width: 540, height: 190), backdrop: .windowBackground, variants: full) {
            JobsRowsSheet(jobs: [JobsSamples.done()], runner: r)
        }
        s.register("jobs.row-failed", size: CGSize(width: 540, height: 170), backdrop: .windowBackground, variants: full) {
            JobsRowsSheet(jobs: [JobsSamples.failed()], runner: r)
        }
        s.register("jobs.row-others", size: CGSize(width: 540, height: 640), backdrop: .windowBackground, variants: SnapshotVariant.lightDark) {
            JobsRowsSheet(jobs: [JobsSamples.paused(), JobsSamples.queued(), JobsSamples.withWarnings(), JobsSamples.doneMany(), JobsSamples.cancelled()], runner: r)
        }
        s.register("jobs.row-a11y", size: CGSize(width: 540, height: 340), backdrop: .windowBackground, variants: a11y) {
            JobsRowsSheet(jobs: [JobsSamples.running(), JobsSamples.done()], runner: r)
        }
        s.register("jobs.window", size: CGSize(width: 580, height: 700), backdrop: .windowBackground, chrome: .window(title: L("Jobs", "Задачи")), variants: full) {
            JobsListView(model: JobsListModel(runner: r, jobs: JobsSamples.mixed()), runner: r, inlineToolbar: true).appRoot()
        }
        s.register("jobs.window-empty", size: CGSize(width: 580, height: 420), backdrop: .windowBackground, chrome: .window(title: L("Jobs", "Задачи")), variants: full) {
            JobsListView(model: JobsListModel(runner: r, jobs: []), runner: r, inlineToolbar: true).appRoot()
        }
        s.register("jobs.toast", size: CGSize(width: 520, height: 330), backdrop: .wallpaper, variants: full) { JobsToastSheet() }
        s.register("jobs.toast-a11y", size: CGSize(width: 520, height: 330), backdrop: .wallpaper, variants: a11y) { JobsToastSheet() }
        s.register("jobs.hud-card", size: CGSize(width: 440, height: 520), backdrop: .wallpaper, variants: full) {
            JobsHUDSheet(jobs: [JobsSamples.running(mode: .quick), JobsSamples.done(), JobsSamples.failed()], runner: r)
        }
        s.register("jobs.hud-card-a11y", size: CGSize(width: 440, height: 340), backdrop: .wallpaper, variants: a11y) {
            JobsHUDSheet(jobs: [JobsSamples.running(mode: .quick), JobsSamples.done()], runner: r)
        }
    }
}
