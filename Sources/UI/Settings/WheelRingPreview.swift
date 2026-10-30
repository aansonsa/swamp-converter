import SwiftUI

/// A small, honest picture of the first ring of a wheel: the same sector geometry as the real wheel (`WheelGeometry`), symbols in the sectors, favourites on the axes, the
/// row the pointer is on lit in the brand tint. It is a preview of the arrangement, not a second wheel: no glass, no animation, nothing to hit-test.
struct WheelRingPreview: View {
    var sectors: [LayoutEditorModel.RingSector]
    var wheel: WheelKind
    var highlighted: String?
    var side: CGFloat = 200
    @Environment(\.a11y) private var a11y

    private var geometry: WheelGeometry {
        let outer = side / 2 - 6
        return WheelGeometry(outerRadius: outer, hubRadius: outer / 3, gap: 3, sectorCount: sectors.count)
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let geo = geometry
                var t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: 1, y: -1)
                let stroke = Color.primary.opacity(a11y.increaseContrast ? 0.6 : 0.16)
                for i in sectors.indices {
                    guard let cg = geo.sectorPath(i).copy(using: &t) else { continue }
                    let path = Path(cg)
                    let lit = sectors[i].id == highlighted
                    ctx.fill(path, with: .color(lit ? Brand.tint.opacity(0.32) : Color.primary.opacity(0.07)))
                    ctx.stroke(path, with: .color(lit ? Brand.tint : stroke), lineWidth: lit ? 1.5 : 0.75)
                }
                if sectors.isEmpty {
                    let ring = Path(ellipseIn: CGRect(x: size.width / 2 - geo.outerRadius, y: size.height / 2 - geo.outerRadius, width: geo.outerRadius * 2, height: geo.outerRadius * 2))
                    ctx.stroke(ring, with: .color(stroke), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                }
                let hub = Path(ellipseIn: CGRect(x: size.width / 2 - geo.hubRadius + 4, y: size.height / 2 - geo.hubRadius + 4,
                                                 width: (geo.hubRadius - 4) * 2, height: (geo.hubRadius - 4) * 2))
                ctx.stroke(hub, with: .color(stroke), lineWidth: 0.75)
            }
            ForEach(Array(sectors.enumerated()), id: \.element.id) { index, sector in
                glyph(sector, at: geometry.labelCenter(of: index))
            }
            Image(systemName: wheel.symbol)
                .symbolRenderingMode(.hierarchical).font(.system(size: 15, weight: DS.symbolWeight)).foregroundStyle(.tertiary)
            if sectors.isEmpty {
                Text(L("Nothing for this kind", "Для этого вида ничего нет"))
                    .font(DS.Typo.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(width: side * 0.5).offset(y: side * 0.22)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Preview of the first ring", "Предпросмотр первого кольца")))
        .accessibilityValue(Text(sectors.map(\.label.text).joined(separator: ", ")))
    }

    @ViewBuilder private func glyph(_ sector: LayoutEditorModel.RingSector, at centre: CGPoint) -> some View {
        let showsText = WheelSector.isFormatLabel(sector.label.en, wheel: wheel) && WheelSector.isFormatLabel(sector.label.ru, wheel: wheel)
        Group {
            if showsText {
                Text(sector.label.text).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Image(systemName: sector.symbol).symbolRenderingMode(.hierarchical).font(.system(size: 15, weight: DS.symbolWeight))
            }
        }
        .foregroundStyle(.primary)
        .overlay(alignment: .topTrailing) {
            if sector.favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Brand.pinkInk).offset(x: 7, y: -6) }
        }
        .offset(x: centre.x, y: -centre.y)
    }
}
