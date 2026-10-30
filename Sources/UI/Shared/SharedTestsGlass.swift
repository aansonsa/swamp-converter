import SwiftUI
import AppKit

// Glass: the SDK APIs the design system builds on are touched at run time, and the Reduce Transparency fallback is proven for the AppKit backing view.

extension SharedTests {
    static func registerGlass(_ t: SelfTestRegistry) {
        t.register("shared", "glass plan: Reduce Transparency selects the opaque surface; outlines grow with Increase Contrast") {
            try expectEqual(GlassPlan.surface(reduceTransparency: false), .glass)
            try expectEqual(GlassPlan.surface(reduceTransparency: true), .opaque)
            try expectClose(Double(GlassPlan.outlineWidth(surface: .glass, increaseContrast: false)), 0)
            try expectClose(Double(GlassPlan.outlineWidth(surface: .glass, increaseContrast: true)), 1)
            try expectClose(Double(GlassPlan.outlineWidth(surface: .opaque, increaseContrast: false)), 0.5)
            try expectClose(Double(GlassPlan.outlineWidth(surface: .opaque, increaseContrast: true)), 1.5)
            try expect(GlassPlan.opaqueTintRing > 0 && GlassPlan.opaqueTintOpacity > 0, "a tint must survive Reduce Transparency as a ring and a wash")
        }

        t.register("shared", "glass APIs exist and behave: Glass, GlassEffectContainer, NSGlassEffectView, NSGlassEffectContainerView") {
            // SwiftUI: the values compose and compare (the compiler already proved the signatures against the SDK).
            let base = Glass.regular
            let tinted = Glass.regular.tint(Brand.pink.opacity(0.35)).interactive()
            try expect(base == Glass.regular && base != tinted && Glass.clear != Glass.regular && Glass.identity != Glass.regular)
            _ = GlassEffectContainer(spacing: 6) { Color.clear.glassEffect(.regular, in: Capsule()) }
            _ = GlassGroup(spacing: 6) { Color.clear.glassSurface(cornerRadius: 12, tint: Brand.pink, interactive: true) }
            // AppKit: the properties the wheel disc relies on round-trip.
            let glass = NSGlassEffectView()
            glass.cornerRadius = 180; glass.tintColor = NSColor.systemPink; glass.style = .clear
            try expectClose(Double(glass.cornerRadius), 180)
            try expectEqual(glass.style, NSGlassEffectView.Style.clear)
            try expect(glass.tintColor != nil)
            glass.style = .regular
            try expectEqual(glass.style, NSGlassEffectView.Style.regular)
            let child = NSView()
            glass.contentView = child
            try expect(glass.contentView === child)
            let container = NSGlassEffectContainerView()
            container.spacing = 6; container.contentView = glass
            try expectClose(Double(container.spacing), 6)
            try expect(container.contentView === glass)
        }

        t.register("shared", "GlassBackingView swaps NSGlassEffectView for the NSVisualEffectView fallback under Reduce Transparency and keeps its content") {
            let content = NSTextField(labelWithString: "content")
            let view = GlassBackingView(cornerRadius: 20, tintColor: .systemPink, reduceTransparency: false)
            view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            view.contentView = content
            try expectEqual(view.backing, .glass)
            let glass = try unwrap(view.subviews.first as? NSGlassEffectView, "glass backing")
            try expect(glass.contentView === content)
            try expectClose(Double(glass.cornerRadius), 20)

            view.reduceTransparency = true
            try expectEqual(view.backing, .visualEffect)
            let effect = try unwrap(view.subviews.first as? NSVisualEffectView, "visual effect backing")
            try expect(content.superview === effect, "content moved into the fallback")
            try expectClose(Double(effect.layer?.cornerRadius ?? -1), 20)
            try expect(effect.layer?.masksToBounds == true && effect.state == .active)
            try expectEqual(view.subviews.count, 2, "one backing and the outline overlay: the old backing is gone")
            try expect(!view.subviews.contains { $0 is NSGlassEffectView }, "the glass view was removed")
            // The fallback paints its own opaque fill (the system only does it when ITS setting is on); the tint is a wash on it and a ring above it.
            let fill = try unwrap(effect.subviews.first as? OpaqueBackingFill, "opaque fill under the content")
            try expect(effect.subviews.firstIndex(of: fill)! < effect.subviews.firstIndex(of: content)!, "the fill sits below the content")
            fill.updateLayer()
            let fillLayer = try unwrap(fill.layer)
            try expectClose(Double(fillLayer.cornerRadius), 20)
            try expect((fillLayer.backgroundColor?.alpha ?? 0) == 1, "the fill is fully opaque")
            try expect(view.subviews.last === view.outlineView, "the outline overlay stays on top of the backing")
            try expectClose(Double(view.outlineView.width), Double(GlassPlan.opaqueTintRing), "the tint survives as a ring")
            try expectClose(Double(view.outlineWidth), Double(GlassPlan.opaqueTintRing))

            // No tint: a hairline, stronger with Increase Contrast.
            view.tintColor = nil
            try expectClose(Double(view.outlineWidth), Double(GlassPlan.outlineWidth(surface: .opaque, increaseContrast: false)))
            view.increaseContrast = true
            try expectClose(Double(view.outlineView.width), Double(GlassPlan.outlineWidth(surface: .opaque, increaseContrast: true)))
            view.increaseContrast = false
            view.tintColor = .systemPink

            // Replacing the content removes the old view from the fallback.
            let other = NSView()
            view.contentView = other
            try expect(content.superview == nil && other.superview === effect, "old content removed, new content placed")
            view.contentView = nil
            try expect(other.superview == nil, "nil content removes the view")
            view.contentView = content

            view.reduceTransparency = false
            try expectEqual(view.backing, .glass)
            try expect((view.subviews.first as? NSGlassEffectView)?.contentView === content, "content is back in the glass")
            try expect(view.subviews.last === view.outlineView, "the outline overlay is still on top after a switch")
            view.usesClearGlass = true
            try expectEqual((view.subviews.first as? NSGlassEffectView)?.style, NSGlassEffectView.Style.clear)
            // Increase Contrast puts a 1 pt outline around the glass (the glass has none of its own); plain glass has none.
            try expectClose(Double(view.outlineView.width), 0)
            view.increaseContrast = true
            try expectClose(Double(view.outlineView.width), 1)
            try expectClose(Double(view.outlineView.cornerRadius), 20, "the outline follows the glass corner")
            view.outlineView.updateLayer()
            try expectClose(Double(view.outlineView.layer?.borderWidth ?? -1), 1)
            try expect(view.outlineView.hitTest(NSPoint(x: 5, y: 5)) == nil, "the overlay never takes a click")
            view.increaseContrast = false
            try expectClose(Double(view.outlineView.width), 0)
        }

        t.register("shared", "AccessibilityObserver is event-driven: it fires when the system posts the display-options change and is released with its owner") {
            var fired = 0
            weak var weakObserver: AccessibilityObserver?
            do {
                let observer = AccessibilityObserver { fired += 1 }
                weakObserver = observer
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
                try await Task.sleep(nanoseconds: 80_000_000)
                try expectEqual(fired, 1)
                withExtendedLifetime(observer) {}
            }
            try expect(weakObserver == nil, "the observer must not outlive its owner")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            try await Task.sleep(nanoseconds: 80_000_000)
            try expectEqual(fired, 1, "no callbacks after release")
        }

        t.register("shared", "no retain cycles: backing views and progress rings are freed (200 created and dropped)") {
            weak var lastGlass: GlassBackingView?
            weak var lastRing: ProgressRingLayerView?
            for i in 0..<200 {
                let g = GlassBackingView(cornerRadius: 10, reduceTransparency: i % 2 == 0)
                g.followSystemAccessibility()
                g.contentView = NSView()
                let r = ProgressRingLayerView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
                r.progress = nil; r.progress = 0.5
                lastGlass = g; lastRing = r
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(lastGlass == nil && lastRing == nil, "views leaked")
        }
    }
}
