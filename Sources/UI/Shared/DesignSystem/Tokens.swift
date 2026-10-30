import SwiftUI
import AppKit

// Design tokens: spacing on the 4 / 8 pt grid, concentric radii, springs, type scale, materials. Native first: these only
// fill the gaps SwiftUI leaves open. No custom skins, no heavy borders or shadows, no gradients as decoration.

enum DS {
    /// 4 / 8 pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Side gutter of windows and sheets.
        static let gutter: CGFloat = 20
    }

    /// Corner radii. A child nested `inset` points inside a parent uses `inner(of:inset:)` so the curves stay concentric.
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 16
        static let sheet: CGFloat = 20
        static func inner(of outer: CGFloat, inset: CGFloat) -> CGFloat { max(outer - inset, 2) }
    }

    /// Springs (response ~0.35, damping ~0.8 for open; faster for hover so the highlight never trails the pointer).
    enum Motion {
        static let open = Animation.spring(response: 0.35, dampingFraction: 0.8)
        static let hover = Animation.spring(response: 0.22, dampingFraction: 0.85)
        static let reduced = Animation.easeInOut(duration: 0.12)
        /// With Reduce Motion: a 0.12 s fade instead of any spring.
        static func animation(_ a: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? reduced : a }
    }

    /// SF Pro text styles with a clear hierarchy (system styles, so Dynamic Type-like scaling and Russian lengths just work).
    enum Typo {
        static let title = Font.title2.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.caption
        static let footnote = Font.footnote
        /// Format tiles on the wheel ("PNG", "MP4"): Display cut, semibold.
        static let tile = Font.system(size: 17, weight: .semibold)
        static let tileSubtitle = Font.system(size: 10, weight: .regular)
        static let mono = Font.system(.callout, design: .monospaced)
        /// Numbers that change (ETA, sizes): fixed-width digits so the layout does not jitter.
        static func numeric(_ base: Font = .callout) -> Font { base.monospacedDigit() }
    }

    /// Materials. Glass lives on the control layer only (wheel disc, toolbars, popovers); content stays on system backgrounds.
    enum Surface {
        static var window: Color { Color(nsColor: .windowBackgroundColor) }
        static var control: Color { Color(nsColor: .controlBackgroundColor) }
        static var separator: Color { Color(nsColor: .separatorColor) }
    }

    /// Symbol weight used everywhere so icons look like one family.
    static let symbolWeight = Font.Weight.medium
}

/// Animates changes of `value` with a design-system spring that becomes a 0.12 s fade when Reduce Motion is on. Use it instead of `.animation(DS.Motion.open, value:)`, so a
/// view never forgets the accessibility option: `.motion(DS.Motion.hover, value: isHovered)`.
private struct MotionModifier<V: Equatable>: ViewModifier {
    var animation: Animation
    var value: V
    @Environment(\.a11y) private var a11y

    func body(content: Content) -> some View {
        content.animation(DS.Motion.animation(animation, reduceMotion: a11y.reduceMotion), value: value)
    }
}

extension View {
    func motion<V: Equatable>(_ animation: Animation = DS.Motion.open, value: V) -> some View { modifier(MotionModifier(animation: animation, value: value)) }
}

/// The SF Symbol a file kind / operation family wears everywhere (chips, queue rows, the wheel profile editor).
extension FileKind {
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .raw: return "camera.aperture"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .slides: return "rectangle.on.rectangle.angled"
        case .spreadsheet: return "tablecells"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .other: return "doc"
        }
    }
}

extension OperationFamily {
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .slides: return "rectangle.on.rectangle.angled"
        case .spreadsheet: return "tablecells"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .ocr: return "text.viewfinder"
        case .download: return "arrow.down.circle"
        case .app: return "square.stack"
        }
    }
}

/// An SF Symbol in the house style: hierarchical rendering, medium weight, scales with the text style.
struct SymbolIcon: View {
    var name: String
    var size: CGFloat? = nil
    var style: HierarchicalShapeStyle = .primary
    init(_ name: String, size: CGFloat? = nil, style: HierarchicalShapeStyle = .primary) { self.name = name; self.size = size; self.style = style }
    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(size.map { .system(size: $0, weight: DS.symbolWeight) } ?? .body.weight(DS.symbolWeight))
            .foregroundStyle(style)
    }
}
