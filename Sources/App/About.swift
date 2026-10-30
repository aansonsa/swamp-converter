import SwiftUI
import AppKit

/// One line of the tool status list.
struct AboutToolRow: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var found: Bool
    /// Folder the tool was found in ("/opt/homebrew/bin"), nil when missing.
    var location: String?

    @MainActor
    static func live(_ locator: ToolLocator = .shared) -> [AboutToolRow] {
        let tools: [Tool] = [.ffmpeg, .ytdlp, .soffice, .pandoc, .magick, .cwebp]
        return tools.map { tool in
            let info = locator.find(tool)
            return AboutToolRow(name: tool.displayName, found: info != nil, location: info.map { $0.url.deletingLastPathComponent().path })
        }
    }
}

/// Facts shown by About, separated so a test and the snapshots can feed them.
struct AboutInfo: Equatable {
    var version: String
    var build: String
    static var current: AboutInfo {
        let info = Bundle.main.infoDictionary
        return AboutInfo(version: info?["CFBundleShortVersionString"] as? String ?? "dev", build: info?["CFBundleVersion"] as? String ?? "0")
    }
    var versionLine: String {
        let v = L("Version \(version)", "Версия \(version)")
        return build == "0" || build.isEmpty ? v : "\(v) (\(build))"
    }
}

enum AboutText {
    /// The credit line of the README ("Благодарности"). The only place in the UI that names the project this app was inspired by.
    static let credit = L10n("Inspired by Sweetch by @mmmorozov (MIT) and the UX of HandBrake. The code is Swift written for this app, with one MIT-licensed library listed under License and notices; no code was taken from either.",
                             "Inspired by Sweetch by @mmmorozov (MIT). Код приложения написан с нуля на Swift; HandBrake использовался только как образец удобства, его код не копировался.")
    static let requirement = L10n("macOS 26 or later", "macOS 26 или новее")
    static let licence = L10n("""
        Swamp Converter is free software under the MIT licence. Copyright 2026 Andris Ansons.

        Optional programs such as ffmpeg (LGPL / GPL), LibreOffice (MPL), Pandoc (GPL), ImageMagick and yt-dlp (Unlicense) are never bundled: Swamp Converter runs the copies you installed yourself, as separate programs, under their own licences. The list of adapted open-source code is in THIRD-PARTY-NOTICES.md.
        """, """
        Swamp Converter распространяется свободно по лицензии MIT. Copyright 2026 Andris Ansons.

        Необязательные программы, такие как ffmpeg (LGPL / GPL), LibreOffice (MPL), Pandoc (GPL), ImageMagick и yt-dlp (Unlicense), в приложение не входят: Swamp Converter запускает установленные вами копии как отдельные программы по их собственным лицензиям. Список использованного открытого кода находится в THIRD-PARTY-NOTICES.md.
        """)
}

/// "Made by" and the owner's mark in Swamp Pink, at the foot of About. A click opens the owner's Instagram in the browser.
struct MadeByLink: View {
    static let url = URL(string: "https://www.instagram.com/aaa.aaa.aaa.aaa.aaa.aaaaaa")!
    static let markHeight: CGFloat = 48

    var body: some View {
        Link(destination: Self.url) {
            VStack(spacing: DS.Space.xs) {
                Text(L("Made by", "Сделано")).font(.footnote).foregroundStyle(.secondary)
                Image(nsImage: BrandArtwork.madeByMark)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: (Self.markHeight * BrandArtwork.madeByAspect).rounded(), height: Self.markHeight)
                    .foregroundStyle(Brand.pink)
            }
            .padding(DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(L("Open the author’s Instagram", "Открыть Instagram автора"))
        .accessibilityLabel(Text(L("Made by the author. Opens Instagram.", "Сделано автором. Открывает Instagram.")))
    }
}

/// A button beside "Show the Welcome Tour" that opens the author's GitHub profile in the browser.
struct AuthorGitHubLink: View {
    static let url = URL(string: "https://github.com/aansonsa")!

    var body: some View {
        Link(destination: Self.url) {
            Label(L("Author on GitHub", "Автор на GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.flatSecondary)
        .pointerStyle(.link)
        .help(L("Open the author’s GitHub profile", "Открыть профиль автора на GitHub"))
    }
}

/// About window / Settings "About" page: the wordmark ornament, version and build, the credit line, the licence note and the status of the optional tools.
struct AboutView: View {
    var info: AboutInfo = .current
    var tools: () -> [AboutToolRow] = { AboutToolRow.live() }
    /// True inside the Settings page (no extra window padding).
    var embedded = false
    var onShowWelcome: (() -> Void)? = { OnboardingController.shared.show() }
    @State private var rows: [AboutToolRow] = []
    @State private var showLicence = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.md) {
                Brand.wordmark(size: 60).padding(.top, DS.Space.lg)
                Text("Swamp Converter").font(DS.Typo.title)
                VStack(spacing: DS.Space.xxs) {
                    Text(info.versionLine).font(DS.Typo.numeric(.callout))
                    Text(AboutText.requirement.text).font(.footnote).foregroundStyle(.secondary)
                }
                Text(AboutText.credit.text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.md)
                toolList
                DisclosureGroup(isExpanded: $showLicence) {
                    Text(AboutText.licence.text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.xs)
                } label: { Text(L("License and notices", "Лицензия и уведомления")).font(.callout.weight(.medium)) }
                .padding(.horizontal, DS.Space.xs)
                HStack(spacing: DS.Space.sm) {
                    if let onShowWelcome {
                        Button(L("Show the Welcome Tour", "Показать вступительный тур")) { onShowWelcome() }.buttonStyle(.flatSecondary)
                    }
                    AuthorGitHubLink()
                }
                MadeByLink().padding(.top, DS.Space.sm)
            }
            .padding(.horizontal, embedded ? DS.Space.gutter : DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 380, idealWidth: 420)
        .background(DS.Surface.window)
        .onAppear { if rows.isEmpty { rows = tools() } }
    }

    private var toolList: some View {
        GlassPanel(cornerRadius: DS.Radius.card, padding: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(L("Optional tools", "Дополнительные программы")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: DS.Space.sm) {
                        StatusDot(row.found ? .done : .idle, size: 12).frame(width: 14)
                        Text(row.name).font(.callout)
                        Spacer(minLength: DS.Space.sm)
                        Text(row.location ?? L("not installed", "не установлено")).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    static let shared = AboutWindowController()
    static let presenceID = "about"
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let w = window { WindowPresence.shared.present(w, id: Self.presenceID); return }
        let host = NSHostingController(rootView: AboutView().appRoot())
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("About Swamp Converter", "О программе Swamp Converter")
        w.contentViewController = host
        w.setContentSize(NSSize(width: 440, height: 640))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        WindowPresence.shared.present(w, id: Self.presenceID)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        WindowPresence.shared.closed(Self.presenceID)
    }

    /// The Settings "About" page is provided here (`SettingsPageID.about`).
    static func registerSettingsPage() {
        SettingsPageRegistry.shared.register(SettingsPageDescriptor(id: .about, title: L10n("About", "О программе"), symbol: "info.circle", order: 100) {
            AnyView(AboutView(embedded: true))
        })
    }
}
