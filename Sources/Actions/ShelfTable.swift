import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The shelf's list: an AppKit table, because only AppKit tells a drag source how the drag ended (copy, move, link or trash) and lets a non-activating panel take
// Delete / Space / double-click without ever activating the app. Rows are file URLs on the pasteboard, so the receiving app decides what a drop means.

/// What the list may ask the rest of the app to do. `live` goes through `ResultActions`; the snapshots and tests pass inert ones.
struct ShelfHandlers {
    var open: ([URL]) -> Void
    var quickLook: ([URL]) -> Void
    var reveal: ([URL]) -> Void
    var copyPaths: ([URL]) -> Void

    @MainActor
    static var live: ShelfHandlers {
        ShelfHandlers(open: { ResultActions.open($0) }, quickLook: { ResultActions.quickLook($0) },
                      reveal: { ResultActions.reveal($0) }, copyPaths: { ResultActions.copyPaths($0) })
    }
    static let inert = ShelfHandlers(open: { _ in }, quickLook: { _ in }, reveal: { _ in }, copyPaths: { _ in })
}

enum ShelfIcon {
    /// The file's own icon; an extension-based one when the file is not there (a restored shelf, a snapshot).
    static func image(for url: URL, points: CGFloat) -> NSImage {
        let image: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let type = UTType(filenameExtension: url.pathExtension) {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        image.size = NSSize(width: points, height: points)
        return image
    }
}

struct ShelfTable: NSViewRepresentable {
    @ObservedObject var model: ShelfModel
    var handlers: ShelfHandlers

    func makeCoordinator() -> ShelfTableCoordinator { ShelfTableCoordinator(model: model, handlers: handlers) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ShelfNSTableView()
        let column = NSTableColumn(identifier: ShelfTableCoordinator.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = ShelfPlacement.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setDraggingSourceOperationMask([.copy, .move, .link, .generic, .delete], forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.draggingDestinationFeedbackStyle = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(ShelfTableCoordinator.doubleClicked(_:))
        table.setAccessibilityLabel(L("Files on the shelf", "Файлы на полке"))
        context.coordinator.table = table
        table.onDelete = { [weak coordinator = context.coordinator] in coordinator?.removeSelected() }
        table.onSpace = { [weak coordinator = context.coordinator] in coordinator?.quickLookSelected() }
        table.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.contextMenuProvider = { [weak coordinator = context.coordinator] row in coordinator?.menu(forRow: row) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: ShelfPlacement.listInset, left: 0, bottom: ShelfPlacement.listInset, right: 0)
        context.coordinator.reloadIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.handlers = handlers
        context.coordinator.reloadIfNeeded()
    }
}

@MainActor
final class ShelfTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("shelf.file")
    static let cellID = NSUserInterfaceItemIdentifier("shelf.cell")

    let model: ShelfModel
    var handlers: ShelfHandlers
    weak var table: ShelfNSTableView?
    private var shownIDs: [UUID] = []
    /// Rows being dragged right now (so the end of the drag knows what to check).
    private var dragged: [URL] = []

    init(model: ShelfModel, handlers: ShelfHandlers) {
        self.model = model
        self.handlers = handlers
    }

    func reloadIfNeeded() {
        let ids = model.entries.map(\.id)
        guard ids != shownIDs else { return }
        shownIDs = ids
        table?.reloadData()
    }

    private var selectedIDs: Set<UUID> {
        guard let table else { return [] }
        return Set(table.selectedRowIndexes.compactMap { model.entries[safe: $0]?.id })
    }

    /// The selection, or every file when nothing is selected.
    private var selectedOrAll: [URL] {
        let ids = selectedIDs
        return ids.isEmpty ? model.urls : model.urls(for: ids)
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ShelfRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = model.entries[safe: row] else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ShelfCellView ?? ShelfCellView()
        cell.identifier = Self.cellID
        cell.configure(url: entry.url)
        return cell
    }

    // MARK: Drag out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        model.entries[safe: row].map { $0.url as NSURL }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragged = rowIndexes.compactMap { model.entries[safe: $0]?.url }
    }

    /// A drag that ended as Move (or into the Trash) took the files away: their rows go too. Copy and link leave the shelf as it is.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let moved = ShelfDragRule.removesRows(after: operation)
        let urls = dragged
        dragged = []
        guard moved else { return }
        // The receiving app may still be finishing the move; look at the disk a moment later, on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.remove(urls: urls.filter { var st = stat(); return lstat($0.path, &st) != 0 })
        }
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: Any?) {
        guard let table, let entry = model.entries[safe: table.clickedRow] else { return }
        handlers.open([entry.url])
    }

    func removeSelected() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        model.remove(ids: ids)   // from the shelf only; the files stay where they are
    }

    func quickLookSelected() { handlers.quickLook(selectedOrAll) }

    /// Return opens the selection only: with nothing selected a stray Return opened every file on the shelf.
    func openSelected() {
        let urls = model.urls(for: selectedIDs)
        if !urls.isEmpty { handlers.open(urls) }
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard let table, let entry = model.entries[safe: row] else { return nil }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let menu = NSMenu()
        func add(_ title: String, symbol: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        _ = entry
        add(L("Open", "Открыть"), symbol: "arrow.up.forward.app") { [weak self] in self?.openSelected() }
        add(L("Show in Finder", "Показать в Finder"), symbol: "magnifyingglass") { [weak self] in
            guard let self else { return }
            self.handlers.reveal(self.model.urls(for: self.selectedIDs))
        }
        add(L("Quick Look", "Быстрый просмотр"), symbol: "eye") { [weak self] in self?.quickLookSelected() }
        add(L("Copy Path", "Копировать путь"), symbol: "link") { [weak self] in
            guard let self else { return }
            self.handlers.copyPaths(self.model.urls(for: self.selectedIDs))
        }
        menu.addItem(.separator())
        add(L("Remove from Shelf", "Убрать с полки"), symbol: "xmark") { [weak self] in self?.removeSelected() }
        return menu
    }
}

/// The one rule about drags out of the shelf, pulled out so it is tested: only a Move (or a drop on the Trash) means the files left.
enum ShelfDragRule {
    static func removesRows(after operation: NSDragOperation) -> Bool {
        operation.contains(.move) || operation.contains(.delete)
    }
}

// MARK: - AppKit pieces

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

final class ShelfNSTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?
    var onOpen: (() -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?

    /// Clicking a row must make the (non-activating) panel key so Delete and Space arrive, without activating the app.
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()          // delete, forward delete
        case 49: onSpace?()                // space
        case 36, 76: onOpen?()             // return, enter
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? contextMenuProvider?(row) : nil
    }
}

/// Selection in the brand tint (never a large fill: a soft rounded wash), hover as a faint wash.
final class ShelfRowView: NSTableRowView {
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isEmphasized: Bool { get { true } set {} }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private var highlightRect: NSRect { bounds.insetBy(dx: 6, dy: 2) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: DS.Radius.control, yRadius: DS.Radius.control).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Brand.tintNSColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: highlightRect, xRadius: DS.Radius.control, yRadius: DS.Radius.control).fill()
    }
}

/// Icon, name (middle-truncated so the extension survives) and the folder the file lives in.
final class ShelfCellView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13, weight: .regular)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.maximumNumberOfLines = 1
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(texts)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.md),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: DS.Space.sm),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.md),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(url: URL) {
        icon.image = ShelfIcon.image(for: url, points: 28)
        name.stringValue = url.lastPathComponent
        let present = FileManager.default.fileExists(atPath: url.path)
        detail.stringValue = present ? url.deletingLastPathComponent().lastPathComponent : L("Not available", "Недоступно")
        detail.textColor = present ? .secondaryLabelColor : .tertiaryLabelColor
        setAccessibilityLabel(url.lastPathComponent)
        setAccessibilityHelp(url.deletingLastPathComponent().path)
        toolTip = url.path
    }
}
