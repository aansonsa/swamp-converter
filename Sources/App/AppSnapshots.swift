import SwiftUI
import AppKit

/// Offscreen snapshots of the app shell: the menu-bar glyph on light and dark menu bars (idle, busy, progress, error), the status menu (real `NSMenu` items drawn as rows), the three
/// onboarding pages and About. Names: `app.*`.
@MainActor
enum AppSnapshots {
    static func register() {
        let r = SnapshotRegistry.shared
        r.register("app.menubar-icon", size: CGSize(width: 420, height: 150), backdrop: .wallpaper, variants: SnapshotVariant.lightDark) { MenuBarIconSheet() }
        r.register("app.menubar-menu", size: CGSize(width: 340, height: 420), backdrop: .wallpaper, variants: SnapshotVariant.lightDarkRu) { MenuBarMenuSheet(items: sampleMenuItems()) }
        for page in OnboardingPage.allCases {
            r.register("app.onboarding-\(page.rawValue + 1)", size: OnboardingView.size, backdrop: .windowBackground, variants: SnapshotVariant.lightDarkRu) {
                OnboardingView(model: OnboardingModel(page: page), settings: SettingsData(), tools: { sampleOnboardingTools })
            }
        }
        r.register("app.about", size: CGSize(width: 440, height: 680), backdrop: .windowBackground, chrome: .window(title: "About Swamp Converter"), variants: SnapshotVariant.lightDarkRu) {
            AboutView(info: AboutInfo(version: "1.0", build: "1"), tools: { sampleAboutTools }, onShowWelcome: {})
        }
    }

    static var sampleOnboardingTools: [OnboardingToolRow] {
        [OnboardingToolRow(name: "ffmpeg", purpose: L10n("Video and audio", "Видео и аудио"), found: true, hint: Tool.ffmpeg.installHint),
         OnboardingToolRow(name: "yt-dlp", purpose: L10n("Downloads from links; installed only if you ask", "Скачивание по ссылкам; ставится только по вашему запросу"), found: false, hint: Tool.ytdlp.installHint),
         OnboardingToolRow(name: "LibreOffice", purpose: L10n("Word, Excel and PowerPoint files", "Файлы Word, Excel и PowerPoint"), found: true, hint: Tool.soffice.installHint)]
    }

    static var sampleAboutTools: [AboutToolRow] {
        [AboutToolRow(name: "ffmpeg", found: true, location: "/opt/homebrew/bin"), AboutToolRow(name: "yt-dlp", found: false, location: nil),
         AboutToolRow(name: "LibreOffice", found: true, location: "/Applications/LibreOffice.app/Contents/MacOS"), AboutToolRow(name: "Pandoc", found: false, location: nil),
         AboutToolRow(name: "ImageMagick", found: true, location: "/opt/homebrew/bin"), AboutToolRow(name: "cwebp", found: true, location: "/opt/homebrew/bin")]
    }

    static func sampleMenuItems() -> [NSMenuItem] {
        let builder = MenuBarMenu()
        return builder.makeMenu().items
    }
}

/// The glyph at 18 pt on a light and a dark menu-bar strip, in every badge state.
struct MenuBarIconSheet: View {
    private let states: [(String, MenuBarBadgeState)] = [("idle", .none), ("busy", .busy), ("40%", .progress(0.4)), ("85%", .progress(0.85)), ("error", .error)]

    var body: some View {
        VStack(spacing: DS.Space.md) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: DS.Space.lg) {
                    ForEach(states, id: \.0) { name, state in
                        VStack(spacing: 2) {
                            ZStack(alignment: .topTrailing) {
                                GlyphRepresentable(tint: dark ? .white : .black)
                                BadgeRepresentable(state: state).frame(width: 10, height: 10).offset(x: 1, y: -1)
                            }
                            .padding(.horizontal, DS.Space.sm).frame(height: 24)
                            .background(dark ? Color.black.opacity(0.78) : Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(name).font(.system(size: 9)).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.lg)
    }
}

struct BadgeRepresentable: NSViewRepresentable {
    var state: MenuBarBadgeState
    func makeNSView(context: Context) -> MenuBarBadgeView { let v = MenuBarBadgeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)); v.apply(state); return v }
    func updateNSView(_ view: MenuBarBadgeView, context: Context) { view.apply(state) }
}

/// A drawing of the status menu built from the REAL menu items, so the snapshot shows what the menu contains in each language.
struct MenuBarMenuSheet: View {
    var items: [NSMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider().padding(.vertical, 3)
                } else {
                    HStack(spacing: DS.Space.sm) {
                        Image(nsImage: item.image ?? NSImage()).frame(width: 18).foregroundStyle(.secondary)
                        Text(item.title).font(.system(size: 13))
                        Spacer(minLength: DS.Space.md)
                        if item.hasSubmenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                        else if !item.keyEquivalent.isEmpty { Text("\u{2318}" + item.keyEquivalent.uppercased()).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, DS.Space.sm).frame(height: 24)
                }
            }
        }
        .padding(DS.Space.sm)
        .frame(width: 280)
        .glassSurface(cornerRadius: DS.Radius.card)
        .padding(DS.Space.lg)
    }
}

/// The glyph drawn by AppKit, as the status item draws it (an image view tinting the template), not by SwiftUI.
private struct GlyphRepresentable: NSViewRepresentable {
    var tint: NSColor
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(image: MenuBarIcon.templateImage(pointSize: 18))
        v.imageScaling = .scaleNone
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { v.contentTintColor = tint }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? { nsView.image?.size }
}
