import SwiftUI

/// The state of a job or a queue entry as one small glyph. Every state has its own SHAPE (ring, disc, bars, check, diamond, triangle), so the meaning
/// never rests on colour alone. Pink appears only for `running` (the brand's "work in progress" dot); the rest use the status inks or neutral greys.
enum StatusKind: CaseIterable, Sendable {
    case idle, waiting, running, paused, done, failed, warning

    var spokenName: L10n {
        switch self {
        case .idle: return L10n("Idle", "Не активно")
        case .waiting: return L10n("Waiting", "Ожидает")
        case .running: return L10n("Running", "Выполняется")
        case .paused: return L10n("Paused", "Приостановлено")
        case .done: return L10n("Done", "Готово")
        case .failed: return L10n("Failed", "Не удалось")
        case .warning: return L10n("Finished with a warning", "Завершено с предупреждением")
        }
    }

    init(_ state: JobState) {
        switch state {
        case .waiting: self = .waiting
        case .running: self = .running
        case .paused: self = .paused
        case .done: self = .done
        case .failed: self = .failed
        case .cancelled, .skipped: self = .idle
        }
    }

    /// A stable id of the drawn shape; the self-test proves every kind differs.
    var shapeID: String {
        switch self {
        case .idle: return "disc.small"
        case .waiting: return "ring"
        case .running: return "disc"
        case .paused: return "bars"
        case .done: return "check"
        case .failed: return "diamond"
        case .warning: return "triangle"
        }
    }
}

struct StatusDot: View {
    var kind: StatusKind
    var size: CGFloat
    @Environment(\.a11y) private var a11y

    init(_ kind: StatusKind, size: CGFloat = 10) { self.kind = kind; self.size = size }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text(kind.spokenName.text))
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: size * 0.5, height: size * 0.5)
        case .waiting:
            Circle().strokeBorder(Color.secondary, lineWidth: max(1, size * 0.16))
        case .running:
            Circle().fill(Brand.tint)
        case .paused:
            HStack(spacing: size * 0.16) {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(Color.secondary)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(Color.secondary)
            }
            .frame(width: size * 0.7, height: size * 0.9)
        case .done:
            Circle().fill(StatusTone.success.fill)
                .overlay { if size >= 12 { Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.background) } }
        case .failed:
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).fill(StatusTone.error.fill)
                .rotationEffect(.degrees(45)).scaleEffect(0.72)
        case .warning:
            TriangleShape().fill(StatusTone.warning.fill).frame(width: size * 0.95, height: size * 0.85)
        }
    }
}

/// An upward triangle with softly rounded corners (the `warning` dot).
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * 0.12
        var p = Path()
        let top = CGPoint(x: rect.midX, y: rect.minY), bl = CGPoint(x: rect.minX, y: rect.maxY), br = CGPoint(x: rect.maxX, y: rect.maxY)
        p.move(to: CGPoint(x: (bl.x + top.x) / 2, y: (bl.y + top.y) / 2))
        p.addArc(tangent1End: top, tangent2End: br, radius: r)
        p.addArc(tangent1End: br, tangent2End: bl, radius: r)
        p.addArc(tangent1End: bl, tangent2End: top, radius: r)
        p.closeSubpath()
        return p
    }
}
