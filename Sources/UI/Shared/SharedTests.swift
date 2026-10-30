import SwiftUI
import AppKit

// Self-tests of the design system's numbers: brand colours, WCAG contrast of every ink on every material, the slant and radius geometry.
// Components, glass and lint tests live in SharedTestsComponents.swift / SharedTestsGlass.swift / SharedTestsLint.swift.

enum SharedTests {
    static let light = ContrastMath.lightMaterials
    static let dark = ContrastMath.darkMaterials

    static func materials(dark isDark: Bool) -> [RGB8] { isDark ? dark : light }

    @MainActor
    static func resolvedRGB(_ color: Color, dark isDark: Bool) -> RGB8 {
        var env = EnvironmentValues()
        env.colorScheme = isDark ? .dark : .light
        let r = color.resolve(in: env)
        func byte(_ f: Float) -> Int { Int((min(max(f, 0), 1) * 255).rounded()) }
        return RGB8(byte(r.red), byte(r.green), byte(r.blue))
    }

    static func registerBrand(_ t: SelfTestRegistry) {
        t.register("shared", "brand colours are the sampled logo colours and fill roles never change with the appearance") {
            try expectEqual(Brand.pinkRGB.hex, "#FF72D9"); try expectEqual(Brand.blueRGB.hex, "#7DA7D9")
            for dark in [false, true] { for ic in [false, true] {
                try expectEqual(BrandRole.pink.rgb(dark: dark, increaseContrast: ic), Brand.pinkRGB)
                try expectEqual(BrandRole.blue.rgb(dark: dark, increaseContrast: ic), Brand.blueRGB)
            } }
            try expectClose(Brand.slant, 6)
        }

        t.register("shared", "brand ink colours meet WCAG: text >= 4.5:1, thin icons >= 3:1, Increase Contrast >= 7:1 on light and dark materials") {
            for role in [BrandRole.pinkInk, .blueInk] {
                for dark in [false, true] {
                    let c = role.rgb(dark: dark, increaseContrast: false)
                    for m in materials(dark: dark) { try expect(ContrastMath.ratio(c, m) >= 4.5, "\(role) \(c.hex) on \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(c, m))") }
                    let hc = role.rgb(dark: dark, increaseContrast: true)
                    for m in materials(dark: dark) { try expect(ContrastMath.ratio(hc, m) >= 7, "IC \(role) \(hc.hex) on \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(hc, m))") }
                }
            }
            // The pure brand colours are fills: they must read as graphics (>= 3:1) on the dark materials where they are used as strokes.
            for m in dark { try expect(ContrastMath.ratio(Brand.pinkRGB, m) >= 3 && ContrastMath.ratio(Brand.blueRGB, m) >= 3) }
            // The app tint: >= 3:1 as a graphic on every material (light and dark), also with Increase Contrast.
            for isDark in [false, true] { for ic in [false, true] {
                let c = BrandRole.tint.rgb(dark: isDark, increaseContrast: ic)
                for m in materials(dark: isDark) { try expect(ContrastMath.ratio(c, m) >= 3, "tint \(c.hex) on \(m.hex) (dark: \(isDark), ic: \(ic)): \(ContrastMath.ratio(c, m))") }
            } }
            try expect(ContrastMath.ratio(RGB8(255, 255, 255), BrandRole.tint.rgb(dark: false, increaseContrast: false)) >= 3.5, "white labels on the light-mode tint")
            // Labels ON a brand fill.
            try expect(ContrastMath.ratio(BrandRole.onPink.rgb(dark: false, increaseContrast: false), Brand.pinkRGB) >= 7)
            try expect(ContrastMath.ratio(BrandRole.onBlue.rgb(dark: false, increaseContrast: false), Brand.blueRGB) >= 7)
            // Sanity of the maths.
            try expectClose(ContrastMath.ratio(RGB8(0, 0, 0), RGB8(255, 255, 255)), 21, tolerance: 0.01)
        }

        t.register("shared", "chip inks keep >= 4.5:1 on the tinted chip fill over every material; Increase Contrast drops the fill and reaches 7:1") {
            for (ink, fill) in [(BrandRole.blueChip, Brand.blueRGB), (BrandRole.pinkChip, Brand.pinkRGB)] {
                for dark in [false, true] {
                    let c = ink.rgb(dark: dark, increaseContrast: false)
                    for m in materials(dark: dark) {
                        let bg = ContrastMath.blend(fill, alpha: ChipStyle.fillOpacity, over: m)
                        try expect(ContrastMath.ratio(c, bg) >= 4.5, "\(ink) \(c.hex) on its fill over \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(c, bg))")
                    }
                    let hc = ink.rgb(dark: dark, increaseContrast: true)
                    for m in materials(dark: dark) { try expect(ContrastMath.ratio(hc, m) >= 7, "IC \(ink) \(hc.hex) on \(m.hex): \(ContrastMath.ratio(hc, m))") }
                }
            }
        }

        t.register("shared", "status inks are text-grade: >= 4.5:1 on every material, >= 7:1 with Increase Contrast, >= 3:1 on their own wash") {
            for tone in StatusTone.allCases {
                for dark in [false, true] {
                    let c = tone.rgb(dark: dark, increaseContrast: false)
                    for m in materials(dark: dark) {
                        try expect(ContrastMath.ratio(c, m) >= 4.5, "\(tone) \(c.hex) on \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(c, m))")
                        let wash = ContrastMath.blend(c, alpha: 0.11, over: m)
                        try expect(ContrastMath.ratio(c, wash) >= 3, "\(tone) on its wash over \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(c, wash))")
                    }
                    let hc = tone.rgb(dark: dark, increaseContrast: true)
                    for m in materials(dark: dark) { try expect(ContrastMath.ratio(hc, m) >= 7, "IC \(tone) \(hc.hex) on \(m.hex) (dark: \(dark)): \(ContrastMath.ratio(hc, m))") }
                }
            }
            // Solid shapes (dots, diamonds, triangles) need only graphic contrast: >= 3:1 on every material, also with Increase Contrast.
            for tone in StatusTone.allCases { for dark in [false, true] { for ic in [false, true] {
                let c = tone.fillRGB(dark: dark, increaseContrast: ic)
                for m in materials(dark: dark) { try expect(ContrastMath.ratio(c, m) >= 3, "\(tone) fill \(c.hex) on \(m.hex) (dark: \(dark), ic: \(ic)): \(ContrastMath.ratio(c, m))") }
            } } }
            // The four tones are told apart by symbol shape and by name, not by colour alone.
            try expectEqual(Set(StatusTone.allCases.map(\.symbol)).count, 4)
            try expectEqual(Set(StatusTone.allCases.map { $0.spokenName.en }).count, 4)
            try expectEqual(Set(StatusTone.allCases.map { $0.spokenName.ru }).count, 4)
        }

        t.register("shared", "progress fills read as graphics: >= 3:1 on every light and dark material, also with Increase Contrast") {
            for role in [BrandRole.tint, .blueFill] {
                for isDark in [false, true] { for ic in [false, true] {
                    let c = role.rgb(dark: isDark, increaseContrast: ic)
                    for m in materials(dark: isDark) { try expect(ContrastMath.ratio(c, m) >= 3, "\(role) \(c.hex) on \(m.hex) (dark: \(isDark), ic: \(ic)): \(ContrastMath.ratio(c, m))") }
                } }
            }
        }

        t.register("shared", "dynamic brand colours follow the appearance and the Increase Contrast override") {
            defer { Brand.contrastOverride = nil }
            for dark in [false, true] {
                Brand.contrastOverride = false
                try expectEqual(resolvedRGB(Brand.pinkInk, dark: dark), BrandRole.pinkInk.rgb(dark: dark, increaseContrast: false), "pinkInk dark: \(dark)")
                try expectEqual(resolvedRGB(Brand.tint, dark: dark), BrandRole.tint.rgb(dark: dark, increaseContrast: false), "tint dark: \(dark)")
                try expectEqual(resolvedRGB(StatusTone.error.ink, dark: dark), StatusTone.error.rgb(dark: dark, increaseContrast: false), "error ink dark: \(dark)")
                Brand.contrastOverride = true
                try expectEqual(resolvedRGB(Brand.blueInk, dark: dark), BrandRole.blueInk.rgb(dark: dark, increaseContrast: true), "blueInk IC dark: \(dark)")
                try expectEqual(resolvedRGB(Brand.blueChipInk, dark: dark), BrandRole.blueChip.rgb(dark: dark, increaseContrast: true), "blueChip IC dark: \(dark)")
            }
            try expectEqual(resolvedRGB(Brand.pink, dark: false), Brand.pinkRGB, "the pure brand pink never changes")
            try expectEqual(resolvedRGB(Brand.blue, dark: true), Brand.blueRGB, "the pure brand blue never changes")
        }
    }

    static func registerGeometry(_ t: SelfTestRegistry) {
        t.register("shared", "slanted fill geometry: empty at 0, full width at 1, right edge leans by the slant angle") {
            let rect = CGRect(x: 0, y: 0, width: 200, height: 10)
            try expect(SlantedFill(fraction: 0, slant: 18).path(in: rect).isEmpty)
            let b = SlantedFill(fraction: 0.5, slant: 18).path(in: rect).boundingRect
            let lean = 10 * tan(18 * Double.pi / 180)
            try expectClose(Double(b.maxX), 100 + lean, tolerance: 0.01)
            try expectClose(Double(b.minX), 0, tolerance: 0.01)
            try expect(SlantedFill(fraction: 1, slant: 18).path(in: rect).boundingRect.maxX >= 200)
        }

        t.register("shared", "slanted badge leans like the logo: the top edge sits right of the bottom edge by height x tan(6 degrees)") {
            let rect = CGRect(x: 0, y: 0, width: 120, height: 100)
            let path = SlantedBadgeShape().path(in: rect)
            let lean = Double(SlantedBadgeShape.lean(height: 100))
            try expectClose(lean, 100 * tan(6 * Double.pi / 180), tolerance: 0.001)
            let b = path.boundingRect
            try expect(b.minX >= -0.01 && b.minX < 1.5 && b.maxX <= 120.01 && b.maxX > 118.5, "bounds \(b)")
            // Points 6 pt inside the right edge: in at the top, out at the bottom; the mirror image on the left.
            try expect(path.contains(CGPoint(x: 114, y: 6)) && !path.contains(CGPoint(x: 114, y: 94)))
            try expect(path.contains(CGPoint(x: 6, y: 94)) && !path.contains(CGPoint(x: 6, y: 6)))
        }

        t.register("shared", "concentric radii never go below 2 pt and the grid is 4 / 8") {
            try expectClose(Double(DS.Radius.inner(of: 16, inset: 4)), 12)
            try expectClose(Double(DS.Radius.inner(of: 6, inset: 20)), 2)
            for v in [DS.Space.xs, DS.Space.sm, DS.Space.md, DS.Space.lg, DS.Space.xl, DS.Space.xxl] { try expectEqual(Int(v) % 4, 0) }
        }

        t.register("shared", "every file kind, operation family and symbol used by the shared components exists in SF Symbols") {
            for k in FileKind.allCases { try expect(NSImage(systemSymbolName: k.symbol, accessibilityDescription: nil) != nil, "missing symbol \(k.symbol)") }
            for f in OperationFamily.allCases { try expect(NSImage(systemSymbolName: f.symbol, accessibilityDescription: nil) != nil, "missing symbol \(f.symbol)") }
            for w in WheelKind.allCases { try expect(NSImage(systemSymbolName: w.symbol, accessibilityDescription: nil) != nil, "missing symbol \(w.symbol)") }
            let own = StatusTone.allCases.map(\.symbol) + ["xmark", "questionmark.circle", "arrow.counterclockwise", "checkmark", "tray"]
            for s in own { try expect(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, "missing symbol \(s)") }
        }
    }
}
