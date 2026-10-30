import SwiftUI

/// The floating card shown after a quick drop (progress, cancel, "Show in Finder" when done). Not focus-stealing; hides itself 4 s after success (`JobHUDController`).
/// A glass card of the control layer: kind icon, title, file name, the slanted bar with percent and ETA, and the buttons that fit the state.
struct JobHUDCard: View {
    private let job: Job
    private let runner: JobRunner
    private let onClose: (() -> Void)?
    @StateObject private var observer: JobRowObserver

    static let width: CGFloat = 360

    init(job: Job, runner: JobRunner? = nil, onClose: (() -> Void)? = nil) {
        let r = runner ?? JobRunner.shared
        self.job = job
        self.runner = r
        self.onClose = onClose
        _observer = StateObject(wrappedValue: JobRowObserver(job: job, runner: r))
    }

    var body: some View {
        let m = JobRowModel.make(observer.snapshot)
        HStack(alignment: .top, spacing: DS.Space.md) {
            JobIconTile(symbol: m.symbol, kind: m.statusKind, showsBadge: [.done, .doneWithWarnings, .failed, .paused].contains(m.phase), size: 36)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if !m.inputLine.isEmpty {
                            Text(m.inputLine).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: DS.Space.sm)
                    trailing(m)
                }
                JobRowBody(model: m, showsChips: false)
                buttons(m)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: Self.width, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(m.accessibilityLabel))
        .jobRowAccessibilityActions(m, job: job, runner: runner)
    }

    /// Running: cancel. Finished: close.
    @ViewBuilder private func trailing(_ m: JobRowModel) -> some View {
        if m.canCancel {
            JobIconButton(symbol: "xmark.circle.fill", label: JobRowActions.title(.cancel)) { JobRowActions.perform(.cancel, job: job, runner: runner) }
        } else if m.phase.isFinished, let onClose {
            JobIconButton(symbol: "xmark", label: SharedStrings.close.text) { onClose() }
        }
    }

    @ViewBuilder private func buttons(_ m: JobRowModel) -> some View {
        if m.hasResult {
            HStack(spacing: DS.Space.sm) {
                Button { JobRowActions.perform(.reveal, job: job, runner: runner) } label: { Label(JobRowActions.title(.reveal), systemImage: "magnifyingglass.circle") }
                if m.outputs.count == 1 {
                    Button { JobRowActions.perform(.open, job: job, runner: runner) } label: { Label(JobRowActions.title(.open), systemImage: "arrow.up.forward.app") }
                }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(nil)
        } else if m.phase == .failed {
            HStack(spacing: DS.Space.sm) {
                Button { JobRowActions.perform(.retry, job: job, runner: runner) } label: { Label(JobRowActions.title(.retry), systemImage: "arrow.clockwise") }
                Button { JobRowActions.perform(.copyError, job: job, runner: runner) } label: { Label(JobRowActions.title(.copyError), systemImage: "doc.on.clipboard") }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(nil)
        }
    }
}

/// The cards stacked in the HUD panel, newest on top. Reports its size so the panel follows every change (a card growing buttons, one leaving).
struct JobHUDStack: View {
    @ObservedObject var model: JobHUDModel
    var onClose: (Job) -> Void
    var onSize: (CGSize) -> Void
    @Environment(\.a11y) private var a11y

    var body: some View {
        GlassGroup(spacing: DS.Space.sm) {
            VStack(spacing: DS.Space.sm) {
                ForEach(model.jobs) { job in
                    JobHUDCard(job: job, onClose: { onClose(job) })
                        .transition(a11y.reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .padding(DS.Space.sm)
        .motion(DS.Motion.open, value: model.jobs.map(\.id))
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { onSize($0) })
    }
}
