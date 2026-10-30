import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The download window's content. One column: the link field on top, the part that follows the state of `DownloadSheetModel` in the middle (empty, fetching, info, list, error,
// started), and the action bar at the bottom. Native controls only; the single pink thing is the Download button (and the selection rings), as the design rules ask.

/// `DownloadSheetView(link:)` keeps the placeholder's signature for callers that embed the sheet (Studio): it owns its own model.
struct DownloadSheetView: View {
    var link: LinkItem?
    @StateObject private var model = DownloadSheetModel()

    var body: some View {
        DownloadSheetContent(model: model, onClose: {})
            .onAppear {
                if let link, model.text.isEmpty { model.text = link.url.absoluteString; model.fetch() }
            }
    }
}

struct DownloadSheetContent: View {
    @ObservedObject var model: DownloadSheetModel
    var onClose: () -> Void
    @Environment(\.a11y) private var a11y
    @State private var dropTargeted = false

    static let size = CGSize(width: 560, height: 660)

    var body: some View {
        VStack(spacing: 0) {
            linkBar
            Divider()
            middle.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            DownloadSheetActionBar(model: model, onClose: onClose)
        }
        .frame(minWidth: Self.size.width, idealWidth: Self.size.width, minHeight: 480, idealHeight: Self.size.height)
        .background(DS.Surface.window)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Brand.tint, lineWidth: 2).padding(DS.Space.xs).allowsHitTesting(false) } }
        .onDrop(of: [UTType.url, UTType.plainText], isTargeted: $dropTargeted) { providers in DownloadLinkDrop.handle(providers, into: model) }
        .animation(DS.Motion.animation(DS.Motion.open, reduceMotion: a11y.reduceMotion), value: model.phase)
    }

    // MARK: Link field

    private var linkBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Paste a link to a video or audio page", "Вставьте ссылку на страницу с видео или звуком"), text: $model.text)
                    .textFieldStyle(.plain).font(DS.Typo.body).disabled(model.phase == .started)
                    .onSubmit { model.primaryAction() }
                    .accessibilityLabel(Text(L("Link", "Ссылка")))
                if !model.text.isEmpty && model.phase != .started {
                    Button { model.reset() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(Text(L("Clear the link", "Очистить ссылку")))
                }
                Button { model.paste() } label: { Label(L("Paste", "Вставить"), systemImage: "doc.on.clipboard") }
                    .controlSize(.small).secondaryButtonLook().disabled(model.phase == .fetching || model.phase == .started)
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            if let reason = model.rejection {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Image(systemName: StatusTone.warning.symbol).foregroundStyle(StatusTone.warning.ink).accessibilityLabel(Text(StatusTone.warning.spokenName.text))
                    Text(reason.message.text).font(DS.Typo.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, DS.Space.gutter).padding(.vertical, DS.Space.md)
    }

    // MARK: The middle

    @ViewBuilder private var middle: some View {
        switch model.phase {
        case .empty: emptyState
        case .fetching: fetchingState
        case .info, .playlist: infoState
        case .failed: failedState
        case .started: startedState
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            if let c = model.clipboardLink {
                ClipboardLinkBanner(link: c, onUse: { model.useClipboardLink() }, onDismiss: { model.dismissClipboardBanner() })
                    .padding(.horizontal, DS.Space.gutter).padding(.top, DS.Space.md)
            }
            EmptyStateView(symbol: "arrow.down.circle", title: L("Download from a link", "Скачать по ссылке"),
                           message: L("Paste the address of a page with a video or music. You will see its quality choices before anything is downloaded.",
                                      "Вставьте адрес страницы с видео или музыкой. Варианты качества будут видны до начала загрузки."))
        }
    }

    private var fetchingState: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.primary.opacity(0.08)).frame(width: 128, height: 72)
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    skeletonBar(width: 260, height: 14)
                    skeletonBar(width: 160, height: 10)
                    HStack(spacing: DS.Space.xs) { skeletonBar(width: 40, height: 18); skeletonBar(width: 52, height: 18); skeletonBar(width: 36, height: 18) }
                }
            }
            VStack(spacing: DS.Space.xs) { ForEach(0..<4, id: \.self) { _ in skeletonBar(width: nil, height: 38) } }
            HStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                Text(L("Getting information about the link…", "Получение сведений о ссылке…")).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel", "Отмена")) { model.cancelFetch() }.controlSize(.small).secondaryButtonLook()
            }
        }
        .padding(DS.Space.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("Getting information about the link", "Получение сведений о ссылке")))
    }

    private func skeletonBar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var infoState: some View {
        Form {
            if let info = model.info {
                Section {
                    DownloadInfoCard(info: info)
                    if model.isLive { InlineMessage(L("This is a live stream that is still running. Try again after it has ended.", "Это прямая трансляция, она ещё идёт. Повторите после её окончания."), tone: .warning) }
                    // Without ffmpeg yt-dlp can only take ready-made single files: the best qualities, chapters, a cover and soft subtitles need it to join the parts.
                    if !model.ffmpegAvailable {
                        InlineMessage(L("ffmpeg is not installed, so the download takes the best single file the site offers (often 720p or less) and cannot be converted afterwards.",
                                        "ffmpeg не установлен, поэтому загрузка возьмёт лучший готовый файл сайта (часто 720p или ниже) и не сможет его перекодировать."),
                                      tone: .warning, fixTitle: L("Open Tools", "Открыть «Инструменты»"), onFix: { SettingsWindowController.shared.show(page: .tools) })
                    }
                    if model.offersWholeList {
                        Button { model.fetch(wholeList: true) } label: { Label(L("This video is part of a list. Show the whole list", "Это видео из списка. Показать весь список"), systemImage: "rectangle.stack") }
                            .buttonStyle(.link).foregroundStyle(Brand.blueInk)
                    }
                }
                if model.phase == .playlist {
                    Section(L("Videos", "Видео")) {
                        PlaylistPickerView(entries: info.entries, selection: $model.selection, estimatedBytes: model.estimatedBytes)
                    }
                }
            }
            DownloadOptionsForm(model: model)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var failedState: some View {
        if let f = model.failure {
            DownloadFailureView(failure: f, model: model).padding(DS.Space.gutter).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var startedState: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 28)).symbolRenderingMode(.hierarchical).foregroundStyle(Brand.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(L("Download started", "Загрузка началась")).font(DS.Typo.title)
                    Text(model.startedTitle).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let job = model.startedJob {
                DownloadStageProgressView(job: job)
                DownloadJobOutcomeView(job: job)
            }
            Text(L("You can close this window. The download goes on, and the progress is in the menu bar and in the Downloads window.",
                   "Это окно можно закрыть. Загрузка продолжится, а прогресс виден в меню-баре и в окне загрузок."))
                .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The error state: the calm message, the inline fix (a browser to sign in with, the JavaScript runtime help, a Settings button) and "Try Again".
struct DownloadFailureView: View {
    var failure: DownloadFailure
    @ObservedObject var model: DownloadSheetModel
    @StateObject private var probe = JSRuntimeProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            InlineMessage(failure.message, tone: .error,
                          fixTitle: showsButtonFix ? failure.fixTitle : nil, onFix: showsButtonFix ? { perform() } : nil)
            if failure.fix == .chooseBrowser { cookiesPicker }
            if failure.fix == .showJSRuntimeHelp { JSRuntimeStatusView(probe: probe) }
        }
    }

    private var showsButtonFix: Bool {
        switch failure.fix { case .openSettings, .installTool, .reviewNotice: return true; default: return false }
    }

    private func perform() {
        switch failure.fix {
        case .openSettings: failure.openSettingsFix()
        case .installTool, .reviewNotice: model.fetch()
        default: break
        }
    }

    private var cookiesPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Picker(L("Use the sign-in of", "Использовать вход из"), selection: Binding(get: { model.deps.settings.data.downloader.cookies }, set: { model.chooseBrowser($0) })) {
                ForEach(CookieBrowser.allCases, id: \.self) { Text($0.title.text).tag($0) }
            }
            Text(L("Only for sites that ask you to sign in. yt-dlp reads the cookies from that browser on this Mac for this download; the app does not keep them.",
                   "Только для сайтов, которые просят войти. yt-dlp читает cookies этого браузера на вашем Mac для этой загрузки; приложение их не хранит."))
                .font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.md)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

/// After a start: a failure of the job itself (private video found during the run, network lost) with its way out. Quiet while the job runs or succeeds.
struct DownloadJobOutcomeView: View {
    @ObservedObject var job: Job

    var body: some View {
        switch job.state {
        case .failed:
            let f = DownloadFailure(message: job.errorMessage ?? L("The download failed.", "Загрузка не удалась."))
            InlineMessage(f.message, tone: .error, fixTitle: f.fix == .openSettings || f.fix == .chooseBrowser ? L("Open Settings", "Открыть настройки") : nil,
                          onFix: { SettingsWindowController.shared.show(page: .downloader) })
        case .done:
            InlineMessage(L("Finished. The file is in your folder.", "Готово. Файл лежит в вашей папке."), tone: .success)
        case .cancelled:
            InlineMessage(L("The download was canceled.", "Загрузка отменена."), tone: .info)
        default:
            EmptyView()
        }
    }
}

/// The bottom bar: Open in Studio on the left, the estimated size, Cancel / Close, and the big call to action.
struct DownloadSheetActionBar: View {
    @ObservedObject var model: DownloadSheetModel
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            if model.phase == .started {
                Button(L("Download Another", "Скачать ещё")) { model.reset() }.secondaryButtonLook()
            } else {
                Button(L("Open in Studio…", "Открыть в Studio…")) { model.openInStudio(); onClose() }
                    .secondaryButtonLook().disabled(model.validURL == nil)
            }
            Spacer(minLength: DS.Space.md)
            if model.phase == .started {
                Button(L("Show Downloads", "Показать загрузки")) { JobsWindowController.shared.show() }.secondaryButtonLook()
                Button(L("Done", "Готово")) { onClose() }.keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            } else {
                Button(L("Cancel", "Отмена")) { onClose() }.keyboardShortcut(.cancelAction).secondaryButtonLook()
                Button { model.primaryAction() } label: { Text(model.primaryTitle).lineLimit(1).fixedSize() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.brandProminent).disabled(!primaryEnabled)
            }
        }
        .padding(.horizontal, DS.Space.gutter).padding(.vertical, DS.Space.md)
    }

    private var primaryEnabled: Bool {
        switch model.phase {
        case .empty, .failed: return model.canFetch
        case .fetching, .started: return false
        case .info, .playlist: return model.canDownload
        }
    }
}

/// A link dragged in from a browser (a URL, or text that contains one).
@MainActor
enum DownloadLinkDrop {
    static func handle(_ providers: [NSItemProvider], into model: DownloadSheetModel) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in apply(url.absoluteString, to: model) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in apply(text, to: model) }
                }
                return true
            }
        }
        return false
    }

    /// Puts the dropped text into the field and fetches when it holds a downloadable link.
    static func apply(_ text: String, to model: DownloadSheetModel) {
        guard model.phase != .started else { return }
        model.text = String(text.prefix(2_100))
        if model.validURL != nil { model.fetch() }
    }
}
