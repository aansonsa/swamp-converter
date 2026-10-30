import SwiftUI
import AppKit

// Self-tests, part 4: the root modifier's contract, haptics, announcements, the adaptive picker, long Russian text in the form building blocks,
// and the glass morphing APIs the wheel builds on.

private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Captures what a view sees in its environment (a probe is the only way to observe `.appRoot()`).
@MainActor
private final class EnvironmentBox { var a11y: A11y?; var tintResolved: Color? }

private struct EnvironmentProbe: View {
    let box: EnvironmentBox
    @Environment(\.a11y) private var a11y
    var body: some View {
        box.a11y = a11y
        return Color.clear.frame(width: 4, height: 4)
    }
}

/// Uses every glass morphing API the wheel relies on, so the compiler and the run time prove them: shared ids, a union, a transition.
private struct GlassMorphProbe: View {
    @Namespace private var ns
    var expanded: Bool
    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Circle().frame(width: 40, height: 40).glassEffect(.regular, in: Circle())
                    .glassEffectID("a", in: ns).glassEffectUnion(id: "pair", namespace: ns).glassEffectTransition(.matchedGeometry)
                Circle().frame(width: 40, height: 40).glassEffect(.regular.tint(Brand.pink.opacity(0.35)).interactive(), in: Circle())
                    .glassEffectID("b", in: ns).glassEffectUnion(id: "pair", namespace: ns).glassEffectTransition(.materialize)
                if expanded {
                    Circle().frame(width: 40, height: 40).glassEffect(.clear, in: Circle()).glassEffectID("c", in: ns).glassEffectTransition(.identity)
                }
                Button("x") {}.buttonStyle(.glass)
            }
        }
    }
}

extension SharedTests {
    static func registerLayout(_ t: SelfTestRegistry) {
        t.register("shared", ".appRoot() puts the effective accessibility options in the environment and keeps Brand's Increase Contrast equal to them") {
            defer { Brand.contrastOverride = nil }
            let forced = A11y(reduceMotion: true, reduceTransparency: true, increaseContrast: true, differentiateWithoutColor: true)
            let box = EnvironmentBox()
            let host = NSHostingView(rootView: EnvironmentProbe(box: box).appRoot().environment(\.a11yOverride, forced))
            host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            _ = host.fittingSize
            host.layoutSubtreeIfNeeded()
            try expectEqual(box.a11y, forced, "an override reaches the views below .appRoot()")
            try expectEqual(Brand.contrastOverride, true, "the brand inks follow the same Increase Contrast value")
            let plain = EnvironmentBox()
            let host2 = NSHostingView(rootView: EnvironmentProbe(box: plain).appRoot().environment(\.a11yOverride, A11y()))
            host2.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            _ = host2.fittingSize
            host2.layoutSubtreeIfNeeded()
            try expectEqual(plain.a11y, A11y())
            try expectEqual(Brand.contrastOverride, false)
        }

        t.register("shared", "haptics: off means silent, ticks are at least 60 ms apart, a throttled tick does not move the clock") {
            Haptics.reset()
            defer { Haptics.reset() }
            try expect(Haptics.shouldFire(now: 10, last: nil, enabled: true))
            try expect(!Haptics.shouldFire(now: 10, last: nil, enabled: false))
            try expect(!Haptics.shouldFire(now: 10.059, last: 10, enabled: true))
            try expect(Haptics.shouldFire(now: 10.06, last: 10, enabled: true))
            try expect(Haptics.tick(.alignment, enabled: true, now: 100, perform: false), "the first tick plays")
            try expect(!Haptics.tick(.alignment, enabled: true, now: 100.03, perform: false), "30 ms later: throttled")
            try expect(!Haptics.tick(.alignment, enabled: true, now: 100.059, perform: false), "a throttled tick does not restart the interval")
            try expect(Haptics.tick(.generic, enabled: true, now: 100.061, perform: false), "60 ms after the last tick that played")
            try expect(!Haptics.tick(.alignment, enabled: false, now: 200, perform: false), "switched off")
            try expect(Haptics.tick(.alignment, enabled: true, now: 200.001, perform: false), "a silent call never consumed the interval")
            try expectEqual(Haptics.Kind.alignment.pattern, .alignment)
            try expectEqual(Haptics.Kind.generic.pattern, .generic)
        }

        t.register("shared", "announcements: problems are prefixed with their tone, calm outcomes are not, the payload carries text and priority") {
            Loc.shared.set(.english)
            defer { Loc.shared.set(.system) }
            let done = NoticeCardContent(title: "Converted 5 files", tone: .success)
            try expectEqual(done.spokenAnnouncement, "Converted 5 files")
            let failed = NoticeCardContent(title: "Couldn't convert holiday.mov", message: "The disk is full.", tone: .error)
            try expectEqual(failed.spokenAnnouncement, "Error. Couldn't convert holiday.mov. The disk is full.")
            let warn = NoticeCardContent(title: "Nothing selected", tone: .warning)
            try expectEqual(warn.spokenAnnouncement, "Warning. Nothing selected")
            Loc.shared.set(.russian)
            try expectEqual(failed.spokenAnnouncement, "Ошибка. Couldn't convert holiday.mov. The disk is full.")
            let info = AccessibilityAnnouncer.userInfo(for: "Done", priority: .high)
            try expectEqual(info[.announcement] as? String, "Done")
            try expectEqual((info[.priority] as? NSNumber)?.intValue, NSAccessibilityPriorityLevel.high.rawValue)
        }

        t.register("shared", "AdaptivePicker is a segmented control while the labels fit and a menu when they do not, for English and Russian labels") {
            var selection = 1
            let binding = Binding(get: { selection }, set: { selection = $0 })
            let en: [(value: Int, label: String)] = [(1, "Best for Apple"), (2, "Maximum"), (3, "Universal")]
            let ru: [(value: Int, label: String)] = [(1, "Лучшее для Apple и других устройств"), (2, "Максимальное качество"), (3, "Универсальный")]
            /// Which AppKit control SwiftUI really built for the picker at `width` (ViewThatFits only instantiates the child it chose).
            @MainActor func control(_ options: [(value: Int, label: String)], width: CGFloat) async -> String {
                let host = NSHostingView(rootView: AdaptivePicker("Mode", selection: binding, options: options).frame(width: width).appRoot())
                host.frame = NSRect(x: 0, y: 0, width: width, height: 80)
                let window = SharedTestKit.offscreenWindow(containing: host)
                defer { window.close() }
                for _ in 0..<10 {
                    host.layoutSubtreeIfNeeded()
                    if SharedTestKit.firstDescendant(of: host, as: NSSegmentedControl.self) != nil { return "segmented" }
                    if SharedTestKit.firstDescendant(of: host, as: NSPopUpButton.self) != nil { return "menu" }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                return "none"
            }
            // SwiftUI sizes the segments of a segmented control equally (the widest label x the count), so the long Russian set needs well over 700 pt.
            let ruShort: [(value: Int, label: String)] = [(1, "Для Apple"), (2, "Максимум"), (3, "Универсально")]
            let wideEN = await control(en, width: 700)
            let wideRUShort = await control(ruShort, width: 700)
            let wideRU = await control(ru, width: 1600)
            try expectEqual(wideEN, "segmented", "three short English labels fit in 700 pt")
            try expectEqual(wideRUShort, "segmented", "three short Russian labels fit in 700 pt")
            try expectEqual(wideRU, "segmented", "the long Russian labels fit when the room is really large")
            let mediumRU = await control(ru, width: 600)
            try expectEqual(mediumRU, "menu", "the long Russian labels do not fit in 600 pt: a menu, not a clipped control")
            for width in [CGFloat(160), 240, 320] {
                let narrow = await control(ru, width: width)
                try expectEqual(narrow, "menu", "at \(Int(width)) pt the long Russian labels fall back to a menu")
            }
            let narrowEN = await control(en, width: 120)
            try expectEqual(narrowEN, "menu", "and so do the English ones when the room is really small")
            try expectEqual(selection, 1, "building the views never changes the value")
        }

        t.register("shared", "form building blocks wrap long Russian text instead of truncating it (SettingsRow, ValueRow, help popover, empty state)") {
            let body = NSFont.preferredFont(forTextStyle: .body)
            let caption = NSFont.preferredFont(forTextStyle: .caption1)
            let callout = NSFont.preferredFont(forTextStyle: .callout)
            let title2 = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
            for width in [CGFloat(280), 360, 520] {
                // A row with a symbol, a switch, a long title and a long help sentence. The text column is at most the row minus the symbol (22 + 12) and the gap (12).
                let row = SettingsRow(longRU, help: longRU, symbol: "folder") { Toggle("", isOn: .constant(true)).labelsHidden() }
                let rowSize = SharedTestKit.fitting(row, width: width)
                let rowNeeded = SharedTestKit.textHeight(longRU, font: body, width: width - 46) + SharedTestKit.textHeight(longRU, font: caption, width: width - 46)
                try expect(rowSize.height >= rowNeeded, "SettingsRow at \(Int(width)): \(rowSize.height) < \(rowNeeded)")
                try expect(rowSize.width <= width + 0.5, "SettingsRow overflows: \(rowSize.width) > \(width)")

                let value = ValueRow(longRU, value: longRU, help: longEN)
                let valueSize = SharedTestKit.fitting(value, width: width)
                try expect(valueSize.height >= SharedTestKit.textHeight(longRU, font: body, width: width), "ValueRow at \(Int(width)): \(valueSize.height)")
                try expect(valueSize.width <= width + 0.5, "ValueRow overflows: \(valueSize.width) > \(width)")

                let empty = EmptyStateView(symbol: "tray", title: longRU, message: longRU)
                let emptySize = SharedTestKit.fitting(empty, width: width)
                let textWidth = min(width - 2 * DS.Space.xl, 360)
                let emptyNeeded = SharedTestKit.textHeight(longRU, font: title2, width: width - 2 * DS.Space.xl) + SharedTestKit.textHeight(longRU, font: callout, width: textWidth)
                try expect(emptySize.height >= emptyNeeded, "EmptyStateView at \(Int(width)): \(emptySize.height) < \(emptyNeeded)")
            }
            let popover = SharedTestKit.fitting(HelpPopoverContent(title: longRU, help: longRU, learnMoreTitle: "Подробнее", onLearnMore: {}), width: 280)
            let popoverNeeded = SharedTestKit.textHeight(longRU, font: callout, width: 248) + SharedTestKit.textHeight(longRU, font: NSFont.preferredFont(forTextStyle: .headline), width: 248)
            try expect(popover.height >= popoverNeeded, "help popover \(popover.height) < \(popoverNeeded)")
            try expectClose(Double(popover.width), 280, tolerance: 0.5, "the popover keeps its width")
        }

        t.register("shared", "glass morphing APIs the wheel builds on exist and render: glassEffectID, glassEffectUnion, glassEffectTransition, the glass button style") {
            for expanded in [false, true] {
                let host = NSHostingView(rootView: GlassMorphProbe(expanded: expanded).appRoot())
                host.frame = NSRect(x: 0, y: 0, width: 400, height: 80)
                let size = host.fittingSize
                try expect(size.width > 80 && size.height > 30, "the probe lays out (expanded: \(expanded)): \(size)")
            }
            // One more circle makes the probe wider: the optional member really takes part in the layout.
            let small = NSHostingView(rootView: GlassMorphProbe(expanded: false).appRoot()).fittingSize
            let large = NSHostingView(rootView: GlassMorphProbe(expanded: true).appRoot()).fittingSize
            try expect(large.width > small.width + 30, "expanded probe \(large.width) vs \(small.width)")
        }

        t.register("shared", "motion tokens: springs for opening and hovering, a 0.12 s fade for Reduce Motion, and .motion(...) keeps the view in sync with the environment") {
            try expect(DS.Motion.animation(DS.Motion.open, reduceMotion: true) == DS.Motion.reduced)
            try expect(DS.Motion.animation(DS.Motion.hover, reduceMotion: true) == DS.Motion.reduced)
            try expect(DS.Motion.animation(DS.Motion.open, reduceMotion: false) == DS.Motion.open)
            try expect(DS.Motion.open != DS.Motion.hover && DS.Motion.open != DS.Motion.reduced)
            // The modifier lays out under both settings without changing the content's size.
            for reduce in [false, true] {
                var a = A11y(); a.reduceMotion = reduce
                let host = NSHostingView(rootView: Color.clear.frame(width: 30, height: 12).motion(value: reduce).appRoot().environment(\.a11yOverride, a))
                try expectEqual(host.fittingSize, CGSize(width: 30, height: 12))
            }
        }

        t.register("shared", "components do not leak: hosting views of the toast, message, bars, ring and thumbnail are released after use (120 created, shown in a window and dropped)") {
            weak var lastHost: NSHostingView<AnyView>?
            var weakHosts: [WeakBox<NSHostingView<AnyView>>] = []
            let missing = URL(fileURLWithPath: "/nonexistent/leak-check.mov")
            for i in 0..<120 {
                let view: AnyView
                switch i % 6 {
                case 0: view = AnyView(NoticeCard(NoticeCardContent(title: "Converting", message: "clip.mov", tone: .info, progress: .determinate(0.4), primary: NoticeAction("Cancel") {}, onClose: {})))
                case 1: view = AnyView(InlineMessage("A warning", severity: .warning, fixTitle: "Fix", onFix: {}, onDismiss: {}))
                case 2: view = AnyView(SlantedProgressBar(value: nil))
                case 3: view = AnyView(SlantedProgressBar(value: 0.5, secondary: true))
                case 4: view = AnyView(ProgressRing(value: nil, size: 18))
                default: view = AnyView(ThumbnailView(url: missing, kind: .video, size: 40))
                }
                let host = NSHostingView(rootView: AnyView(view.appRoot()))
                host.frame = NSRect(x: 0, y: 0, width: 380, height: 120)
                let window = SharedTestKit.offscreenWindow(containing: host)
                host.layoutSubtreeIfNeeded()
                window.close()
                host.removeFromSuperview()
                weakHosts.append(WeakBox(host))
                lastHost = host
            }
            // Give SwiftUI's pending work (tasks, onDisappear) a few turns of the run loop to finish and let go.
            for _ in 0..<20 { try? await Task.sleep(nanoseconds: 25_000_000); if weakHosts.allSatisfy({ $0.value == nil }) { break } }
            let alive = weakHosts.filter { $0.value != nil }.count
            try expect(alive <= 2, "\(alive) of 120 hosting views are still alive (a cycle, or a task that never ends)")
            _ = lastHost
        }

        t.register("shared", "progress bars cost almost no CPU in this process: eight sliding bars and eight bars updated at 10 Hz (the animation runs in the render server)", timeout: 40) {
            /// The SwiftUI way (kept only as the baseline to compare against).
            struct NaiveSlidingBar: View {
                @State private var on = false
                var body: some View {
                    GeometryReader { geo in
                        Capsule().fill(Brand.tint).frame(width: geo.size.width * 0.28).offset(x: on ? geo.size.width * 0.72 : 0)
                            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true } }
                    }.frame(height: 6).background(.quaternary, in: Capsule())
                }
            }
            struct NaiveFillBar: View {
                var value: Double
                var body: some View {
                    SlantedFill(fraction: value, slant: Brand.edgeSlant).fill(Brand.tint).clipShape(Capsule()).frame(height: 6)
                        .background(.quaternary, in: Capsule()).animation(.linear(duration: 0.25), value: value)
                }
            }
            @MainActor final class Driver: ObservableObject { @Published var value = 0.0 }
            struct Bars: View {
                @ObservedObject var driver: Driver
                var naive: Bool
                var sliding: Bool
                var body: some View {
                    VStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { _ in
                            if sliding { if naive { NaiveSlidingBar() } else { SlantedProgressBar(value: nil) } }
                            else { if naive { NaiveFillBar(value: driver.value) } else { SlantedProgressBar(value: driver.value) } }
                        }
                    }.padding(8).frame(width: 320).appRoot()
                }
            }
            /// CPU seconds this process spends while the bars run for 1 s (updated at 10 Hz when they are determinate).
            @MainActor func measure(naive: Bool, sliding: Bool) async throws -> Double {
                let driver = Driver()
                let host = NSHostingView(rootView: AnyView(Bars(driver: driver, naive: naive, sliding: sliding)))
                host.frame = NSRect(x: 0, y: 0, width: 340, height: 160)
                let window = SharedTestKit.offscreenWindow(containing: host)
                window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 300_000_000)   // let the views appear and the animations start
                let start = SharedTestKit.cpuSeconds()
                for i in 0..<10 { driver.value = Double(i) / 10; try await Task.sleep(nanoseconds: 100_000_000) }
                let used = SharedTestKit.cpuSeconds() - start
                // Tear everything down so no SwiftUI animation keeps running after the test (it would disturb whatever runs next).
                host.rootView = AnyView(Color.clear)
                host.removeFromSuperview()
                window.close()
                return used
            }
            func ms(_ s: Double) -> String { String(format: "%.0f", s * 1000) }
            // Ours first: a closed window's SwiftUI animations can linger for a moment, so the expensive baselines run last.
            let slide = try await measure(naive: false, sliding: true)
            let fill = try await measure(naive: false, sliding: false)
            let naiveSlide = try await measure(naive: true, sliding: true)
            let naiveFill = try await measure(naive: true, sliding: false)
            out("      8 bars, 1 s, CPU: sliding \(ms(slide)) ms (SwiftUI repeatForever baseline \(ms(naiveSlide)) ms), updated at 10 Hz \(ms(fill)) ms (SwiftUI animation baseline \(ms(naiveFill)) ms)")
            // Nothing may be left running: after the baselines are gone the process is quiet again.
            try await Task.sleep(nanoseconds: 300_000_000)
            let quietStart = SharedTestKit.cpuSeconds()
            try await Task.sleep(nanoseconds: 700_000_000)
            let residue = SharedTestKit.cpuSeconds() - quietStart
            try expect(residue < 0.05, "the test left something spinning: \(ms(residue)) ms of CPU in 0.7 s after it finished")
            try expect(slide < 0.06, "sliding bars used \(ms(slide)) ms of CPU in 1 s (budget 60 ms for eight bars)")
            try expect(fill < 0.08, "bars updated at 10 Hz used \(ms(fill)) ms of CPU in 1 s (budget 80 ms for eight bars; includes the test's own loop)")
        }

        t.register("shared", "a SlantedProgressBar hosted by SwiftUI draws its fill for the FINAL width, also after the host is resized") {
            let host = NSHostingView(rootView: SlantedProgressBar(value: 0.42).padding(8).appRoot())
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            let window = SharedTestKit.offscreenWindow(containing: host)
            window.orderFrontRegardless()
            defer { window.close() }
            /// Where the fill's slanted right edge really is, in the bar's own coordinates (through the layer tree, so a wrong position or transform shows).
            @MainActor func rightEdge() async -> (width: CGFloat, edge: CGFloat)? {
                for _ in 0..<20 {
                    // No forced layout pass here: the point is what SwiftUI and the window do on their own.
                    if let bar = SharedTestKit.firstDescendant(of: host, as: SlantedBarLayerView.self), bar.bounds.width > 100,
                       let fill = bar.layer?.sublayers?.first as? CAShapeLayer, let root = bar.layer {
                        let w = bar.bounds.width
                        // The shape's right edge at mid height, in the fill layer's space (path x = width), converted to the bar layer's space.
                        let p = fill.convert(CGPoint(x: w, y: bar.bounds.height / 2), to: root)
                        return (w, p.x)
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                return nil
            }
            let first = try unwrap(await rightEdge(), "the bar was created")
            try expectClose(Double(first.width), 284, tolerance: 0.5, "padding 8 on both sides of 300")
            try expectClose(Double(first.edge), 0.42 * 284, tolerance: 0.5, "the fill ends at 42 percent of the REAL width, not of the creation width")
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
            try? await Task.sleep(nanoseconds: 80_000_000)
            let second = try unwrap(await rightEdge())
            try expectClose(Double(second.width), 584, tolerance: 0.5)
            try expectClose(Double(second.edge), 0.42 * 584, tolerance: 0.5, "after the host grew")
        }

        t.register("shared", "typography tokens: the type scale descends, tiles stay readable, numbers use fixed-width digits") {
            let sizes = [NSFont.preferredFont(forTextStyle: .title2).pointSize, NSFont.preferredFont(forTextStyle: .headline).pointSize,
                         NSFont.preferredFont(forTextStyle: .body).pointSize, NSFont.preferredFont(forTextStyle: .callout).pointSize,
                         NSFont.preferredFont(forTextStyle: .caption1).pointSize]
            try expect(sizes == sizes.sorted(by: >), "title >= headline >= body >= callout >= caption: \(sizes)")
            try expect(sizes.last! >= 10, "nothing below the macOS minimum of 10 pt")
            // Fixed-width digits: "1111" and "8888" measure the same in the numeric font.
            let numeric = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            let w1 = ("1111" as NSString).size(withAttributes: [.font: numeric]).width
            let w8 = ("8888" as NSString).size(withAttributes: [.font: numeric]).width
            try expectClose(Double(w1), Double(w8), tolerance: 0.01)
        }

        t.register("shared", "wordmark: the logo's own letters decode, keep the PSD's proportions and scale with the size") {
            let letters = BrandArtwork.swpLetters
            try expect(letters.isTemplate && letters.representations.first?.pixelsWide == 1096 && letters.representations.first?.pixelsHigh == 439,
                       "the embedded PSD letters decode at 1096 x 439: \(letters.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" })")
            let mark = BrandArtwork.madeByMark
            try expect(mark.isTemplate && mark.representations.first?.pixelsWide == 388, "the Made by mark decodes")
            let small = NSHostingView(rootView: Brand.wordmark(size: 20)).fittingSize
            let big = NSHostingView(rootView: Brand.wordmark(size: 60)).fittingSize
            try expect(big.width > small.width * 2.5 && big.height > small.height * 2.5, "scales with the size: \(small) -> \(big)")
            try expectClose(Double(big.width / big.height), Double(BrandArtwork.swpAspect), tolerance: 0.05)
        }
    }
}
