import SwiftUI
import AppKit

// What one sector shows (spec/wheel.md 5): an SF Symbol, a short label and an optional subtitle, centred on the label radius at the sector's mid-angle. Format tiles on the
// Convert wheel ("JPG", "TAR.GZ") are text only. A dimmed sector (its tool is missing) keeps its shape and loses its opacity; the reason shows in the hub when the pointer
// rests on it, so dimming is never the only cue.

struct WheelSectorLabel: View {
    var sector: WheelSector
    var index: Int
    var geometry: WheelGeometry
    var highlighted: Bool
    /// "2/3" for the paging sectors.
    var pageNote: String?
    var isStatic = false
    @Environment(\.a11y) private var a11y
    @State private var grown = false

    var body: some View {
        let k = geometry.outerRadius / WheelGeometry.referenceOuterRadius
        let c = geometry.labelCenter(of: index)
        let dir = geometry.popDirection(of: index)
        let pop: CGFloat = highlighted && !a11y.reduceMotion && geometry.sectorCount > 1 ? WheelGeometry.popDistance : 0
        // A crowded wheel keeps only the page note ("2/2") under the title: the subtitle of the hovered sector is in the hub.
        let subtitle = pageNote ?? (geometry.isCrowded ? nil : sector.subtitle?.text)
        let crowded = geometry.isCrowded
        // Wrap between words only: the size is chosen so that the longest word fits the box (see WheelLabelFit); at the smallest size a longer word is cut with an ellipsis.
        let titleSize = WheelLabelFit.size(for: sector.title.text, width: geometry.labelWidth, base: (crowded ? 11 : 12) * k, minimum: (crowded ? 8.5 : 9) * k, maxLines: 2)
        VStack(spacing: (crowded ? 1 : 2) * k) {
            if sector.isFormatTile {
                Text(sector.title.text)
                    .font(.system(size: (crowded ? 16 : 19) * k, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle, !subtitle.isEmpty { subtitleText(subtitle, k: k) }
            } else {
                Image(systemName: sector.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: (crowded ? 17 : 20) * k, weight: DS.symbolWeight))
                    .frame(height: (crowded ? 20 : 24) * k)
                Text(sector.title.text)
                    .font(.system(size: titleSize ?? (crowded ? 8.5 : 9) * k, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty { subtitleText(subtitle, k: k) }
            }
        }
        .foregroundStyle(.primary)
        .frame(width: geometry.labelWidth)
        .opacity(sector.enabled ? 1 : 0.42)
        .offset(x: c.x + dir.width * pop, y: -c.y + dir.height * pop)
        .opacity(grown || isStatic ? 1 : 0)
        .motion(DS.Motion.hover, value: highlighted)
        .onAppear {
            guard !isStatic else { return }
            let delay = a11y.reduceMotion ? 0 : Double(min(index, 8)) * 0.014
            withAnimation(DS.Motion.animation(.easeOut(duration: 0.17), reduceMotion: a11y.reduceMotion).delay(delay)) { grown = true }
        }
        .allowsHitTesting(false)
    }

    private func subtitleText(_ text: String, k: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10 * k))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
