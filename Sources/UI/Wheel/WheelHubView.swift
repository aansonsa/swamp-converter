import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The hub (spec/wheel.md 6): the cancel zone in the middle of the ring. It says what is being converted (up to three fanned file icons and a count line), what the hovered
// sector will do, or, on the link wheel, which page is meant (title and host). The text comes from `WheelModel.hubContent()`; this file only draws it.

/// File icons for the fan in the hub (`NSWorkspace` icons are cached: the hub redraws on every sector change).
@MainActor
enum WheelIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 24
        return c
    }()

    static func image(for icon: WheelInputSummary.Icon) -> NSImage? {
        switch icon {
        case .symbol: return nil
        case .file(let url):
            let key = "f:" + url.path as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = NSWorkspace.shared.icon(forFile: url.path)
            cache.setObject(img, forKey: key)
            return img
        case .type(let type):
            let key = "t:" + type.identifier as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let img = NSWorkspace.shared.icon(for: type)
            cache.setObject(img, forKey: key)
            return img
        }
    }
}

struct WheelHubContentView: View {
    @ObservedObject var model: WheelModel
    var geometry: WheelGeometry
    @Environment(\.a11y) private var a11y

    var body: some View {
        let k = geometry.outerRadius / WheelGeometry.referenceOuterRadius
        let hub = model.hubContent()
        let side = geometry.panelSide
        let textWidth = geometry.hubRadius * 1.62
        // The title keeps to one line (shrunk to 11 pt at most) so the capsule below never lands on the text; a title that cannot do that takes two lines of 12 pt and the
        // detail line gives way to it. A hint (a disabled sector's reason) needs the room too, so the capsule is not drawn while one is shown.
        let oneLine = WheelLabelFit.size(for: hub.title, width: textWidth, base: 14 * k, minimum: 11 * k, maxLines: 1)
        let twoLines = oneLine == nil
        let drawsCapsule = showsCapsule && !hub.detailIsHint
        let showsDetail = hub.detailIsHint || !(twoLines && drawsCapsule)
        ZStack {
            VStack(spacing: 2 * k) {
                icon(hub, k: k)
                Text(hub.title)
                    .font(.system(size: oneLine ?? 12 * k, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(hub.detailIsHint ? 1 : 2)
                    .truncationMode(.tail)
                if showsDetail {
                    Text(hub.detail)
                        .font(.system(size: (hub.detailIsHint ? 10 : 11) * k))
                        .foregroundStyle(hub.detailIsHint ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(hub.detailIsHint ? 4 : 1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: textWidth)
            .offset(y: drawsCapsule ? -4 * k : 0)

            if model.reachableWheels.count > 1 { wheelDots(k: k) }
            if drawsCapsule { capsule(k: k) }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    @ViewBuilder
    private func icon(_ hub: WheelHubContent, k: CGFloat) -> some View {
        if model.waitingForItems && model.summary.count == 0 && model.highlightedSector == nil && hub.symbol == "tray.and.arrow.down" {
            Brand.wordmark(size: 24 * k)
                .frame(height: 28 * k)
        } else if hub.showsFanIcons && !model.summary.icons.isEmpty {
            fan(model.summary.icons, k: k)
        } else if let symbol = hub.symbol {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22 * k, weight: DS.symbolWeight))
                .foregroundStyle(hub.detailIsHint ? Color.orange : Color.primary)
                .frame(height: 28 * k)
        }
    }

    /// Up to three icons overlapping like a hand of cards.
    private func fan(_ icons: [WheelInputSummary.Icon], k: CGFloat) -> some View {
        let shown = Array(icons.prefix(3))
        let size = 30 * k
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, ic in
                let t = CGFloat(i) - CGFloat(shown.count - 1) / 2
                Group {
                    if let img = WheelIconCache.image(for: ic) {
                        Image(nsImage: img).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "link").font(.system(size: size * 0.7))
                    }
                }
                .frame(width: size, height: size)
                .rotationEffect(.degrees(Double(t) * 9))
                .offset(x: t * 9 * k, y: abs(t) * 2 * k)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
        }
        .frame(height: 32 * k)
    }

    /// Which file wheels the person can reach (the wheel being shown is solid).
    private func wheelDots(k: CGFloat) -> some View {
        HStack(spacing: 5 * k) {
            ForEach(model.reachableWheels, id: \.self) { w in
                Image(systemName: w.symbol)
                    .font(.system(size: 8.5 * k, weight: .semibold))
                    .foregroundStyle(w == model.wheel ? Color.primary : Color.secondary.opacity(0.55))
            }
        }
        .offset(y: -geometry.hubRadius * 0.78)
    }

    private var showsCapsule: Bool {
        !model.waitingForItems && !model.content.isEmpty && !model.content.isRepeatView && !model.isLinkWheel
    }

    /// "Customise..." capsule in the lower hub (opens the Studio with the last hovered sector's target). Also a drop target in drag mode.
    private func capsule(k: CGFloat) -> some View {
        let r = model.capsuleRect
        let hot = model.capsuleHot
        return Text(L("Customize…", "Настроить…"))
            .font(.system(size: 9.5 * k, weight: .semibold))
            .foregroundStyle(hot ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: r.width, height: r.height)
            .background {
                Capsule()
                    .fill(hot ? Brand.pink.opacity(0.28) : Color.primary.opacity(0.07))
                    .overlay { if hot || a11y.increaseContrast { Capsule().strokeBorder(hot ? Brand.tint : Color.primary.opacity(0.5), lineWidth: hot ? 1.5 : 1) } }
            }
            .offset(x: r.midX, y: -r.midY)
    }
}
