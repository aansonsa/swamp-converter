import SwiftUI
import AppKit

// Components: pure models (key caps, flow layout, status kinds), views that must wrap instead of truncate (measured against an independent TextKit
// measurement), the progress ring's Core Animation state, the thumbnail pipeline.

extension SharedTests {
    static let longRU = "Целевой размер файла больше исходного, поэтому сжатие не даст выигрыша: оставьте исходное разрешение или выберите меньший размер."
    static let longEN = "The target size is larger than the source, so compressing will not save anything: keep the original resolution or choose a smaller size."

    static func registerComponents(_ t: SelfTestRegistry) {
        t.register("shared", "InlineMessage maps severities, builds from a schema message and hands back its fix") {
            try expectEqual(StatusTone(OptionSeverity.info), .info)
            try expectEqual(StatusTone(OptionSeverity.warning), .warning)
            try expectEqual(StatusTone(OptionSeverity.error), .error)
            try expectEqual(StatusTone(UserMessage.Severity.warning), .warning)
            var applied: [String: OptionValue]?
            let fix = OptionFix(title: L10n("Use 1080p", "Взять 1080p"), set: ["video.height": .int(1080)])
            let message = OptionMessage(id: "m", severity: .warning, text: L10n("Too large", "Слишком большой"), fieldKey: "video.height", fix: fix)
            let view = InlineMessage(message) { applied = $0.set }
            try expectEqual(view.tone, .warning)
            try expectEqual(view.fixTitle, fix.title.text)
            try expect(view.onFix != nil)
            view.onFix?()
            try expectEqual(applied?["video.height"], .int(1080))
            // Without a handler there is no button; without a fix there is none either.
            try expect(InlineMessage(message).onFix == nil)
            try expect(InlineMessage(OptionMessage(id: "n", severity: .info, text: "x")) { _ in }.onFix == nil)
        }

        t.register("shared", "InlineMessage wraps long Russian and English text instead of truncating it, at every width") {
            for (text, font) in [(longRU, NSFont.preferredFont(forTextStyle: .callout)), (longEN, NSFont.preferredFont(forTextStyle: .callout))] {
                for width in [CGFloat(240), 320, 480, 640] {
                    for withFix in [false, true] {
                        let view = InlineMessage(text, severity: .warning, detail: withFix ? text : nil,
                                                 fixTitle: withFix ? "Оставить исходный размер / Keep the original size" : nil, onFix: withFix ? {} : nil, onDismiss: {})
                        let size = SharedTestKit.fitting(view, width: width)
                        // The widest the text can be is the card minus padding (24), icon (20) and spacing (12): that gives the fewest lines, so a lower bound.
                        let needed = SharedTestKit.textHeight(text, font: font, width: width - 56)
                        try expect(size.height >= needed, "width \(Int(width)) fix \(withFix): fitting \(size.height) < text \(needed): truncated")
                        try expect(size.width <= width + 0.5, "the message overflows its width: \(size.width) > \(width)")
                    }
                }
            }
        }

        t.register("shared", "StatusDot: every state has its own shape and its own spoken name; every job state maps") {
            try expectEqual(Set(StatusKind.allCases.map(\.shapeID)).count, StatusKind.allCases.count, "shapes must differ")
            try expectEqual(Set(StatusKind.allCases.map { $0.spokenName.en }).count, StatusKind.allCases.count)
            try expectEqual(Set(StatusKind.allCases.map { $0.spokenName.ru }).count, StatusKind.allCases.count)
            let states: [JobState] = [.waiting, .running, .paused, .done, .failed, .cancelled, .skipped]
            try expectEqual(StatusKind(.running), .running)
            try expectEqual(StatusKind(.failed), .failed)
            try expectEqual(StatusKind(.cancelled), .idle)
            try expectEqual(Set(states.map { StatusKind($0) }).count, 6, "waiting running paused done failed idle")
            let path = TriangleShape().path(in: CGRect(x: 0, y: 0, width: 10, height: 9))
            try expect(!path.isEmpty && path.contains(CGPoint(x: 5, y: 6)) && !path.contains(CGPoint(x: 0.3, y: 0.3)))
        }

        t.register("shared", "KeyCap formatting: macOS modifier order, localised Space, named keys, unknown keys") {
            let wheel = HotkeyCombo(keyCode: HotkeyCombo.space, modifiers: HotkeyModifier.control | HotkeyModifier.option)
            let all = HotkeyCombo(keyCode: 13, modifiers: HotkeyModifier.command | HotkeyModifier.shift | HotkeyModifier.option | HotkeyModifier.control)
            let download = HotkeySetting.downloadDefault.combo
            try expectEqual(KeyCapFormat.caps(for: all).map(\.glyph), ["\u{2303}", "\u{2325}", "\u{21E7}", "\u{2318}", "W"])
            try expectEqual(KeyCapFormat.caps(for: download).map(\.glyph), ["\u{2303}", "\u{2325}", "D"])
            Loc.shared.set(.english)
            try expectEqual(KeyCapFormat.caps(for: wheel).map(\.glyph), ["\u{2303}", "\u{2325}", "Space"])
            try expectEqual(KeyCapFormat.spoken(for: wheel), "Control Option Space")
            Loc.shared.set(.russian)
            try expectEqual(KeyCapFormat.caps(for: wheel).map(\.glyph), ["\u{2303}", "\u{2325}", "Пробел"])
            try expectEqual(KeyCapFormat.key(200).glyph, "#200")
            try expectEqual(KeyCapFormat.key(200).spoken, "Клавиша 200")
            Loc.shared.set(.system)
            try expectEqual(KeyCapFormat.key(36).glyph, "\u{21A9}")
            try expectEqual(KeyCapFormat.key(53).spoken, "Escape")
            try expectEqual(KeyCapFormat.caps(for: HotkeyCombo(keyCode: 0, modifiers: 0)).count, 1)
        }

        t.register("shared", "FlowLayout wraps whole items, keeps order, gives an over-wide item its own row, and is fast") {
            let sizes = [CGSize(width: 60, height: 20), CGSize(width: 50, height: 24), CGSize(width: 40, height: 20), CGSize(width: 90, height: 20)]
            let a = FlowLayout.arrange(sizes: sizes, maxWidth: 120, spacing: 6, lineSpacing: 4)
            try expectEqual(a.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 66, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 0, y: 52)])
            try expectClose(Double(a.size.height), 72)
            try expectClose(Double(a.size.width), 116)
            let one = FlowLayout.arrange(sizes: [CGSize(width: 300, height: 20)], maxWidth: 100, spacing: 6, lineSpacing: 4)
            try expectEqual(one.origins, [CGPoint(x: 0, y: 0)])
            try expectClose(Double(one.size.width), 300)
            try expectEqual(FlowLayout.arrange(sizes: [], maxWidth: 100, spacing: 6, lineSpacing: 4).size, .zero)
            let many = (0..<500).map { CGSize(width: CGFloat(30 + $0 % 40), height: 20) }
            let t0 = Date()
            for _ in 0..<20 { _ = FlowLayout.arrange(sizes: many, maxWidth: 360, spacing: 6, lineSpacing: 6) }
            try expect(Date().timeIntervalSince(t0) < 0.25, "500 chips x 20 layouts took \(Date().timeIntervalSince(t0)) s")
        }

        t.register("shared", "InfoChip wraps a long Russian label to a second line instead of cutting it") {
            let text = "Максимальное качество без перекодирования"
            let size = SharedTestKit.fitting(InfoChip(text, symbol: "film"), width: 160)
            try expect(size.width <= 160.5)
            let oneLine = SharedTestKit.textHeight(text, font: .systemFont(ofSize: 11, weight: .medium), width: 1000)
            try expect(size.height > oneLine + 8, "the chip did not wrap: height \(size.height)")
        }

        t.register("shared", "ProgressRingLayerView: clamped value, error is a full ring, indeterminate spins only in a window and never with Reduce Motion") {
            try expectEqual(ProgressRingLayerView.normalized(nil), nil)
            try expectEqual(ProgressRingLayerView.normalized(-3), 0)
            try expectEqual(ProgressRingLayerView.normalized(7), 1)
            try expectEqual(ProgressRingLayerView.normalized(.nan), 0)
            let ring = ProgressRingLayerView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            ring.progress = 0.25
            try expectClose(ring.strokeEnd, 0.25)
            ring.isError = true
            try expectClose(ring.strokeEnd, 1)
            ring.isError = false
            ring.progress = nil
            try expectClose(ring.strokeEnd, ProgressRingLayerView.indeterminateArc)
            try expect(!ring.isSpinning, "no window, no animation")
            let window = SharedTestKit.offscreenWindow(containing: ring)
            try expect(ring.isSpinning, "indeterminate in a window spins (a render-server animation, no timer)")
            ring.reduceMotion = true
            try expect(!ring.isSpinning, "Reduce Motion: a static arc")
            ring.reduceMotion = false
            ring.progress = 0.6
            try expect(!ring.isSpinning, "a determinate ring never spins")
            try expectEqual(ring.accessibilityValue() as? String, "60%")
            ring.progress = nil
            try expect(ring.isSpinning)
            ring.removeFromSuperview()
            try expect(!ring.isSpinning, "leaving the window removes the animation")
            window.close()
        }

        t.register("shared", "progress bar layer: indeterminate slide exists only inside a window, never with Reduce Motion, restarted when the width changes") {
            let bar = SlantedBarLayerView(frame: NSRect(x: 0, y: 0, width: 200, height: 6))
            try expect(bar.isIndeterminate && !bar.isSliding, "no window, no animation")
            let window = SharedTestKit.offscreenWindow(containing: bar)
            bar.layout()
            try expect(bar.isSliding, "in a window the segment slides (Core Animation, no per-frame work in this process)")
            let layer = try unwrap(bar.layer?.sublayers?.first as? CAShapeLayer, "fill layer")
            let slide = try unwrap(layer.animation(forKey: SlantedBarLayerView.slideKey) as? CABasicAnimation)
            try expectEqual(slide.keyPath, "transform.translation.x")
            try expect(slide.autoreverses && slide.repeatCount == .infinity)
            try expectClose((slide.toValue as? Double) ?? -1, 200 * SlantedBarLayerView.travelFraction, tolerance: 0.01, "the segment ends flush with the right end")
            // The geometry: 28 percent of the width plus the lean of the top edge.
            let b = SlantedBarLayerView.segmentPath(in: CGSize(width: 200, height: 6)).boundingBox
            let lean = 6 * tan(Brand.edgeSlant * Double.pi / 180)
            try expectClose(Double(b.maxX), 200 * SlantedBarLayerView.segmentFraction + lean, tolerance: 0.01)
            try expectClose(Double(b.minX), 0, tolerance: 0.01)
            // Wider bar: the travel distance follows.
            bar.frame = NSRect(x: 0, y: 0, width: 300, height: 6)
            bar.layout()
            let wider = try unwrap(layer.animation(forKey: SlantedBarLayerView.slideKey) as? CABasicAnimation)
            try expectClose((wider.toValue as? Double) ?? -1, 300 * SlantedBarLayerView.travelFraction, tolerance: 0.01)
            bar.reduceMotion = true
            try expect(!bar.isSliding, "Reduce Motion: a static segment")
            bar.reduceMotion = false
            try expect(bar.isSliding)
            // Becoming determinate stops the slide; becoming indeterminate again restarts it.
            bar.fraction = 0.5
            try expect(!bar.isSliding && !bar.isIndeterminate, "a determinate bar does not slide")
            bar.fraction = nil
            try expect(bar.isSliding, "indeterminate again: the slide is back")
            bar.removeFromSuperview()
            try expect(!bar.isSliding, "leaving the window removes the animation")
            window.close()
        }

        t.register("shared", "progress bar layer: determinate fill matches the SwiftUI shape, glides in the render server, hides at 0 and clamps bad values") {
            // The drawn outline equals SlantedFill's: right edge at f x width, top leaning right by height x tan(18 degrees).
            let size = CGSize(width: 200, height: 6)
            let lean = 6 * tan(Brand.edgeSlant * Double.pi / 180)
            let path = SlantedBarLayerView.fillPath(in: size)
            for f in [0.25, 0.5, 1.0] {
                let dx = SlantedBarLayerView.translation(forFraction: f, width: size.width)
                let moved = path.copy(using: [CGAffineTransform(translationX: dx, y: 0)]) ?? path
                let swiftUI = SlantedFill(fraction: CGFloat(f), slant: Brand.edgeSlant).path(in: CGRect(origin: .zero, size: size)).boundingRect
                // Compare the right edge (layer space is y-up, so the leaning TOP edge is at y = height).
                try expectClose(Double(moved.boundingBox.maxX), Double(swiftUI.maxX), tolerance: 0.01, "right edge at \(f)")
                try expect(moved.contains(CGPoint(x: size.width * f - 1, y: 3)), "the fill covers just left of the edge at \(f)")
                try expect(!moved.contains(CGPoint(x: size.width * f + lean + 1, y: 3)), "and nothing right of it at \(f)")
            }
            try expectEqual(SlantedBarLayerView.normalized(nil), nil)
            try expectEqual(SlantedBarLayerView.normalized(-1), 0)
            try expectEqual(SlantedBarLayerView.normalized(3), 1)
            try expectEqual(SlantedBarLayerView.normalized(.nan), 0)
            try expectClose(Double(SlantedBarLayerView.translation(forFraction: 1, width: 200)), 0)
            try expectClose(Double(SlantedBarLayerView.translation(forFraction: 0, width: 200)), -200)

            let bar = SlantedBarLayerView(frame: NSRect(x: 0, y: 0, width: 200, height: 6))
            bar.fraction = 0
            let window = SharedTestKit.offscreenWindow(containing: bar)
            bar.layout()
            let layer = try unwrap(bar.layer?.sublayers?.first as? CAShapeLayer, "fill layer")
            try expect(layer.isHidden, "nothing is drawn at 0")
            try expect(!bar.isSliding && !bar.isIndeterminate)
            // Core Animation only creates implicit animations for a layer that has been committed to the render server once: show the (far off-screen) window.
            window.orderFrontRegardless()
            CATransaction.flush()
            try? await Task.sleep(nanoseconds: 60_000_000)
            bar.fraction = 0.6
            try expect(!layer.isHidden)
            // Frame and transform together: the shape's right edge, seen from the bar's layer, is at 60 percent of the width.
            try expectClose(Double(layer.position.x), 100, tolerance: 0.01, "the layer sits centred in the bar; the translation is the transform's job")
            try expectClose(Double(layer.convert(CGPoint(x: 200, y: 3), to: bar.layer).x), 120, tolerance: 0.01)
            try expectClose(Double(layer.transform.m41), -80, tolerance: 0.01, "60 percent of 200 pt: the shape sits 80 pt left of full")
            try expect(layer.animationKeys()?.contains("transform") == true, "the glide is an implicit animation the render server interpolates")
            bar.frame = NSRect(x: 0, y: 0, width: 400, height: 6)
            try expectClose(Double(layer.convert(CGPoint(x: 400, y: 3), to: bar.layer).x), 240, tolerance: 0.01, "after a resize the edge is still at 60 percent")
            try expectClose(Double(layer.position.x), 200, tolerance: 0.01, "and the layer stays centred in the wider bar")
            try expectClose(Double(layer.transform.m41), -160, tolerance: 0.01)
            bar.frame = NSRect(x: 0, y: 0, width: 200, height: 6)
            try expectClose(Double(layer.transform.m41), -80, tolerance: 0.01)
            bar.reduceMotion = true
            layer.removeAllAnimations()
            bar.fraction = 0.9
            try expect(layer.animationKeys()?.contains("transform") != true, "Reduce Motion: the value jumps")
            try expectClose(Double(layer.transform.m41), -20, tolerance: 0.01)
            bar.fraction = .nan
            try expect(layer.isHidden, "NaN counts as 0")
            window.close()
        }

        t.register("shared", "thumbnails: sizes round up to cache buckets and the cache decodes at most the requested pixels") {
            try expectEqual(ThumbnailSizing.maxPixel(points: 40, scale: 2), 128)
            try expectEqual(ThumbnailSizing.maxPixel(points: 44, scale: 2), 128)
            try expectEqual(ThumbnailSizing.maxPixel(points: 32, scale: 1), 64)
            try expectEqual(ThumbnailSizing.maxPixel(points: 120, scale: 2), 256)
            try expectEqual(ThumbnailSizing.maxPixel(points: 5000, scale: 2), 1024)
            try expectEqual(ThumbnailSizing.maxPixel(points: 0, scale: 0), 64)
            let fx = TestFixtures(label: "shared-thumb")
            defer { fx.cleanup() }
            let png = try fx.png("tall photo with spaces, dots.v2.png", width: 600, height: 300)
            let image = try unwrap(await ThumbnailCache.shared.thumbnail(for: png, kind: .image, maxPixel: 128, scale: 2), "thumbnail")
            try expectEqual(image.width, 128)
            try expectEqual(image.height, 64)
            let again = try unwrap(await ThumbnailCache.shared.thumbnail(for: png, kind: .image, maxPixel: 128, scale: 2))
            try expect(again === image, "second request is a cache hit")
        }

        t.register("shared", "NoticeCard keeps one width and wraps long Russian titles, messages and actions") {
            let content = NoticeCardContent(title: longRU, message: longEN, tone: .error, progress: .determinate(0.4),
                                            primary: NoticeAction("Повторить с другими настройками") {}, secondary: NoticeAction("Показать в Finder") {}, onClose: {})
            let size = SharedTestKit.fitting(NoticeCard(content), width: NoticeCard.width)
            try expectClose(Double(size.width), Double(NoticeCard.width), tolerance: 0.5)
            let titleHeight = SharedTestKit.textHeight(longRU, font: .systemFont(ofSize: 12, weight: .semibold), width: NoticeCard.width - 24 - 24 - 12 - 18 - 12)
            let messageHeight = SharedTestKit.textHeight(longEN, font: .preferredFont(forTextStyle: .caption1), width: NoticeCard.width - 24 - 24 - 12 - 18 - 12)
            try expect(size.height >= titleHeight + messageHeight, "card \(size.height) < title \(titleHeight) + message \(messageHeight): truncated")
            // From a one-line message.
            let m = UserMessage(severity: .warning, text: "Nothing selected", symbol: "exclamationmark.triangle")
            let fromMessage = NoticeCardContent(m)
            try expectEqual(fromMessage.tone, .warning)
            try expectEqual(fromMessage.title, "Nothing selected")
            try expectEqual(fromMessage.symbol, "exclamationmark.triangle")
            let calm = SharedTestKit.fitting(NoticeCard(NoticeCardContent(title: "Done")), width: NoticeCard.width)
            try expect(calm.height < size.height && calm.height > 30)
        }
    }
}
