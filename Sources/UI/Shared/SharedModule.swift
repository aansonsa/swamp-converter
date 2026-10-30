import SwiftUI

// MODULE shared (owner: design-system engineer). Sources/UI/Shared/*.
// Tokens (DS), the Brand enum, status tones, glass (GlassPlan, glassSurface, GlassBackingView), and the components every UI module uses:
// GlassPanel, SettingsRow / SettingsToggleRow, InfoChip / KindChip, SlantedProgressBar, EmptyStateView, InlineMessage, StatusDot, ModifiedBadge,
// HelpPopoverButton / HelpLabel, KeyCapView, ProgressRing, ThumbnailView, FormSection / FormFootnote / ValueRow, FlowLayout, NoticeCard (+ AccessibilityAnnouncer),
// AdaptivePicker (segmented while it fits, a menu when Russian labels do not), Haptics (throttled alignment ticks), `.appRoot()`.
// Every UI module imports these and never defines its own colours, radii, springs or paddings.

enum SharedModule {
    #if !SC_SHIPPING
    @MainActor
    static func registerSnapshots() {
        let s = SnapshotRegistry.shared
        let full = SnapshotVariant.lightDarkRu
        let a11y = SnapshotVariant.accessibility
        s.register("shared.tokens", size: CGSize(width: 560, height: 420), backdrop: .windowBackground, variants: full) { TokensSheet() }
        s.register("shared.brand", size: CGSize(width: 560, height: 520), backdrop: .wallpaper, variants: full) { BrandSheet() }
        s.register("shared.components", size: CGSize(width: 560, height: 560), backdrop: .wallpaper, variants: full) { ComponentsSheet() }
        s.register("shared.components-a11y", size: CGSize(width: 560, height: 560), backdrop: .wallpaper, variants: a11y) { ComponentsSheet() }
        s.register("shared.messages", size: CGSize(width: 520, height: 560), backdrop: .windowBackground, variants: full) { MessagesSheet() }
        s.register("shared.messages-a11y", size: CGSize(width: 520, height: 560), backdrop: .windowBackground, variants: a11y) { MessagesSheet() }
        s.register("shared.indicators", size: CGSize(width: 640, height: 600), backdrop: .windowBackground, variants: full) { IndicatorsSheet() }
        s.register("shared.indicators-a11y", size: CGSize(width: 640, height: 600), backdrop: .windowBackground, variants: a11y) { IndicatorsSheet() }
        s.register("shared.forms", size: CGSize(width: 560, height: 700), backdrop: .windowBackground, variants: full) { FormsSheet() }
        s.register("shared.notice", size: CGSize(width: 440, height: 560), backdrop: .wallpaper, variants: full) { NoticeSheet() }
        s.register("shared.notice-a11y", size: CGSize(width: 440, height: 560), backdrop: .wallpaper, variants: a11y) { NoticeSheet() }
        s.register("shared.thumbnails", size: CGSize(width: 520, height: 340), backdrop: .windowBackground, variants: SnapshotVariant.lightDark + [SnapshotVariant(increaseContrast: true)]) { ThumbnailsSheet() }
        s.register("shared.chips", size: CGSize(width: 520, height: 300), backdrop: .windowBackground, variants: full + [SnapshotVariant(increaseContrast: true), SnapshotVariant(dark: true, increaseContrast: true)]) { ChipsSheet() }
        s.register("shared.glass", size: CGSize(width: 560, height: 450), backdrop: .wallpaper, variants: full) { GlassSheet() }
        s.register("shared.glass-a11y", size: CGSize(width: 560, height: 450), backdrop: .wallpaper, variants: a11y) { GlassSheet() }
        registerWordmarkSnapshots()
        registerPickerSnapshots()
    }
    #endif

    #if !SC_SHIPPING
    static func registerSelfTests() {
        let t = SelfTestRegistry.shared
        SharedTests.registerBrand(t)
        SharedTests.registerGeometry(t)
        SharedTests.registerGlass(t)
        SharedTests.registerComponents(t)
        SharedTests.registerLayout(t)
        SharedTests.registerLint(t)
    }
    #endif
}
