import SwiftUI
import AppKit

@MainActor
final class JobHUDModel: ObservableObject {
    @Published var jobs: [Job] = []
}

/// Owns the HUD panel: one card per quick job, newest on top, top right under the menu bar of the screen with the pointer. The panel is created at the first card, never takes focus,
/// leaves when the last card does. A successful card hides itself four seconds after the job ended (held back while the pointer is over the panel); a failure or a partial
/// success stays until it is closed; a cancelled job's card disappears at once.
@MainActor
final class JobHUDController {
    static let shared = JobHUDController()
    static let autoHideDelay: TimeInterval = 4
    static let afterHoverDelay: TimeInterval = 2
    static let maxCards = 4

    let model = JobHUDModel()
    /// Tests turn the window off and drive the logic only.
    var showsPanel = true
    private let scheduler: ToastScheduler
    private var panel: JobsFloatingPanel?
    private var host: HoverHostingView<AnyView>?
    private var cancels: [UUID: () -> Void] = [:]
    private var heldBack: Set<UUID> = []
    private var hovering = false
    private var batches: Set<UUID> = []
    private var contentSize = CGSize.zero

    init(scheduler: ToastScheduler = DispatchToastScheduler()) { self.scheduler = scheduler }

    var jobs: [Job] { model.jobs }

    /// Has a card for a job of this batch been shown (the finished-batch notification would only repeat it)?
    func handled(batch: UUID) -> Bool { batches.contains(batch) }
    func forget(batch: UUID) { batches.remove(batch) }

    // MARK: Cards

    func add(_ job: Job) {
        guard !model.jobs.contains(where: { $0.id == job.id }) else { return }
        model.jobs.insert(job, at: 0)
        batches.insert(job.batchID)
        while model.jobs.count > Self.maxCards, let drop = model.jobs.last(where: { $0.state.isFinished }) ?? model.jobs.last { remove(drop) }
        showPanel()
    }

    /// A job ended (finished, failed or cancelled): decide the card's fate.
    func jobEnded(_ job: Job) {
        guard model.jobs.contains(where: { $0.id == job.id }) else { return }
        switch job.state {
        case .cancelled, .skipped: remove(job)
        case .done where job.failures.isEmpty: scheduleHide(job, after: Self.autoHideDelay)
        default: break
        }
    }

    func remove(_ job: Job) {
        cancels.removeValue(forKey: job.id)?()
        heldBack.remove(job.id)
        model.jobs.removeAll { $0.id == job.id }
        if model.jobs.isEmpty { panel?.orderOut(nil); contentSize = .zero }
    }

    private func scheduleHide(_ job: Job, after delay: TimeInterval) {
        cancels.removeValue(forKey: job.id)?()
        let id = job.id
        cancels[id] = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.cancels[id] = nil
            guard let card = self.model.jobs.first(where: { $0.id == id }), card.state == .done else { return }   // retried meanwhile
            if self.hovering { self.heldBack.insert(id) } else { self.remove(card) }
        }
    }

    /// The pointer entered or left the panel: nothing disappears under it; after it leaves, held-back cards go after a short grace.
    func hover(_ inside: Bool) {
        hovering = inside
        guard !inside else { return }
        for id in heldBack {
            if let job = model.jobs.first(where: { $0.id == id }) { scheduleHide(job, after: Self.afterHoverDelay) }
        }
        heldBack.removeAll()
    }

    // MARK: Window

    private func showPanel() {
        guard showsPanel else { return }
        if panel == nil {
            let stack = JobHUDStack(model: model, onClose: { [weak self] job in self?.remove(job) }, onSize: { [weak self] size in self?.sizeChanged(size) })
            let view = HoverHostingView(rootView: AnyView(stack.appRoot()))
            view.onHoverChange = { [weak self] inside in self?.hover(inside) }
            let p = JobsFloatingPanel(contentSize: NSSize(width: JobHUDCard.width + 16, height: 120))
            p.contentView = view
            panel = p
            host = view
            host?.layoutSubtreeIfNeeded()
            let fit = view.fittingSize
            if fit.width > 1 { contentSize = fit }
        }
        place()
        panel?.orderFrontRegardless()
    }

    private func sizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != contentSize else { return }
        contentSize = size
        place()
    }

    /// Keeps the top right corner where it is while the height changes.
    private func place() {
        guard let panel, contentSize.width > 1 else { return }
        let screen = FloatingPlacement.screen(containing: NSEvent.mouseLocation)
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: contentSize)
        let origin = FloatingPlacement.topRight(in: visible, size: contentSize, inset: DS.Space.sm)
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
    }
}
