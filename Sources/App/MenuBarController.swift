import AppKit
import Combine

/// The status item: a menu, not a popover (HIG): live status row, "Recent Results", Add Files..., Open Studio, Download from Link..., Wheel for Clipboard, Pause Gestures, Settings..., About,
/// Quit (`MenuBarMenu`). The icon is a monochrome TEMPLATE image ("swp" glyph); the pink only appears as a small dot / progress ring / diamond (`MenuBarBadgeView`) while jobs run or an
/// error is unseen. The icon is a drop target: files and links dropped on it open the wheel under it (same router as the Dock). The user can hide the icon (`settings.showMenuBarIcon`);
/// the settings change is applied live. The Dock menu mirrors the commands. Everything is event-driven: Combine subscriptions to the job model and the settings, no timers.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let menuBuilder = MenuBarMenu()
    private let dockBuilder = MenuBarMenu(isDock: true)
    private var badge: MenuBarBadgeView?
    private var bag = Set<AnyCancellable>()
    private var wasShown: Bool?

    var isInstalled: Bool { statusItem != nil }

    func install() {
        menuBuilder.anchorProvider = { [weak self] in self?.anchorBelowItem() }
        applyVisibility()
        AppSettings.shared.$revision.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyVisibility() }.store(in: &bag)
        let m = MenuBarProgressModel.shared
        Publishers.CombineLatest4(m.$fraction, m.$running, m.$waiting, m.$hasUnseenError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fraction, running, waiting, error in self?.update(fraction: fraction, running: running, waiting: waiting, error: error) }
            .store(in: &bag)
    }

    func dockMenu() -> NSMenu? { dockBuilder.makeMenu() }

    /// The menu of the status item (nil when the icon is hidden). Tests read its structure.
    var menu: NSMenu? { statusItem?.menu }

    // MARK: Visibility

    private func applyVisibility() {
        let show = AppSettings.shared.data.showMenuBarIcon
        guard show != wasShown else { return }
        wasShown = show
        if show { createItem() } else { removeItem() }
    }

    private func createItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SwampConverterStatusItem"
        if let button = item.button {
            button.image = MenuBarIcon.templateImage(pointSize: 18)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Swamp Converter")
            let badge = MenuBarBadgeView(frame: .zero)
            badge.translatesAutoresizingMaskIntoConstraints = false
            let drop = MenuBarDropView(frame: .zero)
            drop.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badge)
            button.addSubview(drop)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 10), badge.heightAnchor.constraint(equalToConstant: 10),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1), badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
                drop.leadingAnchor.constraint(equalTo: button.leadingAnchor), drop.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                drop.topAnchor.constraint(equalTo: button.topAnchor), drop.bottomAnchor.constraint(equalTo: button.bottomAnchor)])
            self.badge = badge
            drop.onDrop = { [weak self] urls in URLRouter.handle(urls, origin: .menubar, anchor: self?.anchorBelowItem()) }
        }
        item.menu = menuBuilder.makeMenu()
        statusItem = item
        let m = MenuBarProgressModel.shared
        update(fraction: m.fraction, running: m.running, waiting: m.waiting, error: m.hasUnseenError)
    }

    private func removeItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        badge = nil
    }

    // MARK: State

    private func update(fraction: Double?, running: Int, waiting: Int, error: Bool) {
        let state = MenuBarBadgeState.from(fraction: fraction, running: running, waiting: waiting, hasUnseenError: error)
        if badge?.state != state { badge?.apply(state) }
        let title = MenuBarMenu.statusTitle(running: running, waiting: waiting, paused: JobRunner.shared.queuePaused, line: MenuBarProgressModel.shared.statusLine, unseenError: error)
        statusItem?.button?.toolTip = running + waiting > 0 || error ? "Swamp Converter: " + title : "Swamp Converter"
        statusItem?.button?.setAccessibilityValue(running + waiting > 0 ? title : (error ? L("A job failed", "Задача завершилась ошибкой") : nil))
    }

    /// Where the wheel should open for a command chosen from the menu: just below the status item.
    private func anchorBelowItem() -> NSPoint? {
        guard let frame = statusItem?.button?.window?.frame else { return nil }
        return NSPoint(x: frame.midX, y: frame.minY - 8)
    }
}
