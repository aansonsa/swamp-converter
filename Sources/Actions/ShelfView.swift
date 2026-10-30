import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The content of one floating shelf: header (pin, title, close), the list or an empty drop area, and the hint. Glass is the panel itself (control layer); the rows
/// sit on it as plain text and icons. Dropping files on it adds them; the pink drop-target glow shows while a drag hovers.
struct ShelfContentView: View {
    @ObservedObject var model: ShelfModel
    var handlers: ShelfHandlers
    var onClose: () -> Void
    @State private var targeted = false
    @Environment(\.a11y) private var a11y

    static let hint = L10n("Drag items out, or drop more here.", "Перетащите файлы отсюда или добавьте новые сюда.")

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isEmpty { emptyBody } else { list }
            footer
        }
        .frame(width: ShelfPlacement.width, height: ShelfPlacement.height(rows: model.entries.count))
        .glassSurface(cornerRadius: DS.Radius.panel, tint: targeted ? Brand.pink : nil)
        .motion(DS.Motion.hover, value: targeted)
        .onDrop(of: [UTType.fileURL], delegate: ShelfDropDelegate(targeted: $targeted) { urls in model.add(urls) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Floating shelf", "Плавающая полка"))
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            SymbolIcon("pin.fill", size: 13, style: .secondary)
                .rotationEffect(.degrees(45))
                .accessibilityHidden(true)
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.sm)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("Close the shelf", "Закрыть полку"))
            .accessibilityLabel(L("Close the shelf", "Закрыть полку"))
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: ShelfPlacement.headerHeight)
        .background(WindowDragArea())
    }

    private var list: some View {
        ShelfTable(model: model, handlers: handlers)
            .frame(height: ShelfPlacement.listHeight(rows: model.entries.count))
    }

    private var emptyBody: some View {
        VStack(spacing: DS.Space.xs) {
            SymbolIcon("tray.and.arrow.down", size: 22, style: .secondary)
            Text(L("Drop files here", "Перетащите файлы сюда"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ShelfPlacement.emptyBodyHeight)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(a11y.increaseContrast ? 1 : 0.6)
            Text(Self.hint.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.md)
                .frame(maxHeight: .infinity)
        }
        .frame(height: ShelfPlacement.footerHeight)
    }
}

/// The header moves the panel: the panel is not movable by its background, so the rows below can start file drags.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Accepts file drops with the Copy effect only (a drop never moves anything), highlights while hovering, de-duplicates through the model.
struct ShelfDropDelegate: DropDelegate {
    var targeted: Binding<Bool>
    var accept: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.fileURL]) }
    func dropEntered(info: DropInfo) { targeted.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        ShelfDrop.fileURLs(from: providers) { urls in
            Task { @MainActor in accept(urls) }
        }
        return true
    }
}

enum ShelfDrop {
    /// Reads the file URLs out of dropped item providers (in order), then calls `completion` once, on an arbitrary thread.
    static func fileURLs(from providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let slots = Locked([URL?](repeating: nil, count: providers.count))
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let u as URL: url = u
                case let u as NSURL: url = u as URL
                default: url = nil
                }
                if let url, url.isFileURL { slots.withLock { $0[index] = url } }
            }
        }
        group.notify(queue: .global()) { completion(slots.value.compactMap { $0 }) }
    }
}
