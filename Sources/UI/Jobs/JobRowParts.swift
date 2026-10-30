import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Small pieces of a job row: the icon tile, the stage chain, the draggable result chip, the icon button and an anchor for the Share menu.

/// The operation's symbol on a quiet rounded tile. A finished, failed or paused job wears the state glyph in the corner (shape + colour, never colour alone).
struct JobIconTile: View {
    var symbol: String
    var kind: StatusKind
    var showsBadge: Bool
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.46, weight: DS.symbolWeight))
                    .foregroundStyle(.secondary)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    StatusDot(kind, size: 12)
                        .padding(1.5)
                        .background(Circle().fill(DS.Surface.window))
                        .offset(x: 4, y: 4)
                }
            }
            .accessibilityHidden(true)
    }
}

/// "Downloading 62% > Converting": the finished steps quiet, the running one strong, the rest faint.
struct JobStageChain: View {
    var segments: [StageSegment]

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, s in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                label(s)
            }
        }
        .font(DS.Typo.numeric(.caption))
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func label(_ s: StageSegment) -> some View {
        let text = s.percent.map { "\(s.title) \(Loc.percent($0))" } ?? s.title
        switch s.state {
        case .running: Text(text).fontWeight(.semibold).foregroundStyle(.primary)
        case .done: Text(text).foregroundStyle(.secondary)
        case .failed: Text(text).fontWeight(.semibold).foregroundStyle(StatusTone.error.ink)
        default: Text(text).foregroundStyle(.tertiary)
        }
    }
}

/// A result file as a chip: its icon and name. DRAG it into any app (the receiver gets a copy), double-click to open it.
struct OutputChip: View {
    var url: URL
    @Environment(\.a11y) private var a11y

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.chip + 2, style: .continuous)

    var body: some View {
        HStack(spacing: DS.Space.xs + 2) {
            Image(nsImage: Self.icon(for: url)).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            Text(url.lastPathComponent).font(DS.Typo.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(Color.primary.opacity(0.07), in: Self.shape)
        .overlay { if a11y.increaseContrast { Self.shape.strokeBorder(Color.primary.opacity(0.6), lineWidth: 1) } }
        .frame(maxWidth: 280, alignment: .leading)
        .contentShape(Self.shape)
        .onDrag { ResultActions.dragItem(for: url) }
        .onTapGesture(count: 2) { ResultActions.open([url]) }
        .help(L("Drag into another app, double-click to open", "Перетащите в другую программу, двойной щелчок открывает"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(url.lastPathComponent))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L("Open", "Открыть"))) { ResultActions.open([url]) }
    }

    static func icon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }
}

/// A 24 x 24 pt icon button: a quiet glyph, a faint round highlight while pressed. Plain style on purpose: bordered or borderless buttons would colour the glyph with the pink tint.
struct JobIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).font(.system(size: 13, weight: DS.symbolWeight))
        }
        .buttonStyle(JobIconButtonStyle())
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

struct JobIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(Circle())
    }
}

/// Hands the NSView behind a SwiftUI view to `onCreate`, so the Share menu can hang from the button that opened it.
struct ViewAnchor: NSViewRepresentable {
    var onCreate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onCreate(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
