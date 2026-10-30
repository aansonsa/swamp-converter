import SwiftUI

// Snapshot sheets, part 1: tokens, brand, the original components. Reviewed by eye in light / dark / RU and the accessibility variants.

struct SnapshotFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .appRoot()
    }
}

struct TokensSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Text(L("Design tokens", "Токены дизайна")).font(DS.Typo.title)
                HStack(alignment: .bottom, spacing: DS.Space.md) {
                    ForEach([DS.Space.xs, DS.Space.sm, DS.Space.md, DS.Space.lg, DS.Space.xl, DS.Space.xxl], id: \.self) { v in
                        VStack(spacing: DS.Space.xs) {
                            Rectangle().fill(Brand.blue).frame(width: v, height: v)
                            Text("\(Int(v))").font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: DS.Space.lg) {
                    ForEach([DS.Radius.chip, DS.Radius.control, DS.Radius.card, DS.Radius.panel], id: \.self) { r in
                        RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(.secondary, lineWidth: 1).frame(width: 64, height: 64)
                            .overlay(Text("\(Int(r))").font(DS.Typo.caption))
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(L("Title", "Заголовок")).font(DS.Typo.title)
                    Text(L("Headline", "Подзаголовок")).font(DS.Typo.headline)
                    Text(L("Body text in SF Pro", "Основной текст в SF Pro")).font(DS.Typo.body)
                    Text(L("Callout and secondary information", "Пояснение и второстепенные сведения")).font(DS.Typo.callout).foregroundStyle(.secondary)
                    Text(L("Caption", "Подпись")).font(DS.Typo.caption).foregroundStyle(.secondary)
                    Text("12:41:07  1 234,5 MB").font(DS.Typo.numeric())
                }
                HStack(spacing: DS.Space.lg) {
                    ForEach(["photo", "film", "waveform", "doc.richtext", "archivebox", "arrow.down.circle"], id: \.self) { SymbolIcon($0, size: 22) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct BrandSheet: View {
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(spacing: DS.Space.lg) {
                    Brand.wordmark(size: 54)
                    Brand.wordmark(size: 28, color: Brand.pinkInk)
                    Brand.wordmark(size: 18, color: Brand.blueInk)
                }
                GlassPanel {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        HStack(spacing: DS.Space.md) {
                            swatch("pink", Brand.pink); swatch("blue", Brand.blue); swatch("pinkInk", Brand.pinkInk); swatch("blueInk", Brand.blueInk)
                            swatch("tint", Brand.tint); swatch("blueFill", Brand.blueFill)
                        }
                        HStack(spacing: DS.Space.md) {
                            swatch("ok", StatusTone.success.ink); swatch("warn", StatusTone.warning.ink); swatch("error", StatusTone.error.ink); swatch("info", StatusTone.info.ink)
                        }
                        Text(L("Text in pinkInk stays readable", "Текст цветом pinkInk остаётся читаемым")).foregroundStyle(Brand.pinkInk)
                        Text(L("Text in blueInk stays readable", "Текст цветом blueInk остаётся читаемым")).foregroundStyle(Brand.blueInk)
                        FlowLayout {
                            InfoChip("HEVC", symbol: "film"); InfoChip(L("Quick recipe", "Быстрый рецепт"), emphasized: true); KindChip(kind: .video)
                            ModifiedBadge(); InfoChip(L("Maximum quality without re-encoding", "Максимальное качество без перекодирования"), symbol: "sparkles")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func swatch(_ name: String, _ c: Color) -> some View {
        VStack(spacing: DS.Space.xs) {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(c).frame(width: 56, height: 40)
            Text(name).font(DS.Typo.caption)
        }
    }
}

struct ComponentsSheet: View {
    @State private var toggle = true
    @State private var slider = 0.6
    var body: some View {
        SnapshotFrame {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        SlantedProgressBar(value: 0.42)
                        SlantedProgressBar(value: 1, secondary: true)
                        SlantedProgressBar(value: 0.08)
                        SlantedProgressBar(value: nil)
                        HStack(spacing: DS.Space.md) {
                            Button(L("Start", "Начать")) {}.buttonStyle(.brandProminent)
                            Button(L("Cancel", "Отмена")) {}.secondaryButtonLook()
                            Button(L("Add to Queue", "В очередь")) {}.secondaryButtonLook()
                        }
                    }
                }
                VStack(spacing: 0) {
                    Form {
                        SettingsToggleRow(L("Start at login", "Запускать при входе"), help: L("Opens the menu-bar icon after you sign in.", "Показывает значок в строке меню после входа в систему."), isOn: $toggle)
                        SettingsRow(L("Quality", "Качество")) { Slider(value: $slider).frame(width: 140) }
                    }
                    .formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 130)
                    EmptyStateView(symbol: "tray", title: L("Drag files onto the wheel", "Перетащите файлы на колесо"),
                                   message: L("Shake the files while you drag, or press the shortcut.", "Потрясите файлы во время перетаскивания или нажмите сочетание клавиш."), showsWordmark: true)
                        .frame(height: 200)
                }
                .background(DS.Surface.window, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            }
        }
    }
}
