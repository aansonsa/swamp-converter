import SwiftUI
import AppKit

// First-use consent and the explicit yt-dlp install offer. Two questions, asked one after the other by `DownloadService.ensureReady()`:
//   1. DownloadConsentView        "This feature uses the network and a third-party tool." Agree / Not now. Only Agree writes `settings.downloader.consentGiven`.
//   2. DownloadInstallOfferView   "yt-dlp is not installed." One explicit button; progress, the SHA-256 result and any error in plain words.
// Neither sheet imitates a system alert (spec/ux.md 5): a normal window with a heading, short paragraphs, and the buttons at the bottom.

/// The words of the notice, shared by the sheet, the Settings page and the tests.
enum DownloadNotice {
    static let heading = L10n("Download from links", "Скачивание по ссылкам")
    static let points: [(symbol: String, text: L10n)] = [
        ("network", L10n("This feature uses the internet. It is the only part of Swamp Converter that does, and only when you start a download.",
                         "Эта функция использует интернет. Это единственная часть Swamp Converter, которая это делает, и только когда вы начинаете загрузку.")),
        ("shippingbox", L10n("It works through yt-dlp, a free third-party program. It is not part of this app and is installed only when you press the button for it.",
                             "Она работает через yt-dlp, бесплатную стороннюю программу. Она не входит в это приложение и устанавливается только по вашей кнопке.")),
        ("hand.raised", L10n("Use it only for content you have the right to download. The terms of a site may restrict downloading, and the responsibility is yours.",
                             "Используйте её только для материалов, которые вам разрешено скачивать. Правила сайта могут запрещать загрузку, и ответственность на вас."))
    ]
    static let legalTitle = L10n("Legal notice", "Юридическое уведомление")
    static let legalText = L10n("Swamp Converter does not host, index or provide any media. It starts yt-dlp (Unlicense) on a link you give it and processes the result on your Mac. "
                                + "You are responsible for complying with copyright law and the terms of the sites you use. DRM-protected media is never downloaded. "
                                + "Details of the third-party software are in THIRD-PARTY-NOTICES.",
                                "Swamp Converter не хранит, не индексирует и не предоставляет медиафайлы. Приложение запускает yt-dlp (Unlicense) для ссылки, которую вы указали, "
                                + "и обрабатывает результат на вашем Mac. Вы сами отвечаете за соблюдение авторского права и правил используемых сайтов. "
                                + "Материалы под защитой DRM не скачиваются. Сведения о стороннем ПО — в THIRD-PARTY-NOTICES.")
    static let usageLine = L10n("Use only for content you have the right to download; platform terms may restrict downloading.",
                                "Используйте только для материалов, которые вам разрешено скачивать; правила платформ могут ограничивать загрузку.")
}

/// Writes the answer. Pure enough to test without a window.
enum DownloadConsent {
    @discardableResult
    static func record(_ agreed: Bool, in settings: AppSettings = .shared) -> Bool {
        if agreed { settings.update { $0.downloader.consentGiven = true } }
        return agreed
    }
}

/// First-use consent sheet. Agree writes `consentGiven`; Not now writes nothing.
struct DownloadConsentView: View {
    var onFinish: (Bool) -> Void
    var settings: AppSettings = .shared
    @State private var showLegal = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "arrow.down.circle").font(.system(size: 30, weight: DS.symbolWeight)).symbolRenderingMode(.hierarchical).foregroundStyle(Brand.tint)
                    .accessibilityHidden(true)
                Text(DownloadNotice.heading.text).font(DS.Typo.title).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(DownloadNotice.points.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                        Image(systemName: DownloadNotice.points[i].symbol).frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(DownloadNotice.points[i].text.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showLegal) {
                Text(DownloadNotice.legalText.text).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.xs).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(DownloadNotice.legalTitle.text).font(DS.Typo.callout)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L("Not Now", "Не сейчас")) { onFinish(DownloadConsent.record(false, in: settings)) }
                    .keyboardShortcut(.cancelAction).secondaryButtonLook()
                Button(L("Agree and Continue", "Согласен, продолжить")) { onFinish(DownloadConsent.record(true, in: settings)) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 480, height: 400)
        .background(DS.Surface.window)
    }
}

/// "yt-dlp is not installed": the explicit install button with progress and the checksum result.
struct DownloadInstallOfferView: View {
    var onFinish: (Bool) -> Void
    @StateObject private var model = YtDlpInstallModel()
    @StateObject private var probe = JSRuntimeProbe()

    init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

    var body: some View {
        DownloadInstallOfferBody(phase: model.phase, probe: probe, onInstall: { model.install() }, onCancel: {
            model.cancel(); onFinish(false)
        }, onContinue: { onFinish(true) })
    }
}

/// The pure layout of the install offer (the snapshots render it in every phase).
struct DownloadInstallOfferBody: View {
    var phase: YtDlpInstallModel.Phase
    var probe: JSRuntimeProbe
    var onInstall: () -> Void
    var onCancel: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "shippingbox").font(.system(size: 28, weight: DS.symbolWeight)).symbolRenderingMode(.hierarchical).foregroundStyle(Brand.tint)
                    .accessibilityHidden(true)
                Text(L("Install yt-dlp", "Установка yt-dlp")).font(DS.Typo.title)
            }
            Text(L("yt-dlp is the free program that reads links and fetches the media. Swamp Converter does not include it. Pressing Install downloads the official release from github.com, "
                   + "checks its SHA-256 checksum and puts it in this app's own folder. If the check fails, nothing is installed.",
                   "yt-dlp — бесплатная программа, которая читает ссылки и получает медиа. В Swamp Converter её нет. Кнопка «Установить» скачивает официальный релиз с github.com, "
                   + "проверяет его контрольную сумму SHA-256 и кладёт в папку приложения. Если проверка не пройдена, ничего не устанавливается."))
                .fixedSize(horizontal: false, vertical: true)
            statusBlock
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(L("JavaScript runtime (for YouTube)", "JavaScript-движок (для YouTube)")).font(DS.Typo.headline)
                JSRuntimeStatusView(probe: probe, compact: true)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(DS.Space.xl)
        .frame(width: 520, height: 520)
        .background(DS.Surface.window)
    }

    @ViewBuilder private var statusBlock: some View {
        switch phase {
        case .idle: EmptyView()
        case .working(let kind, let progress):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                SlantedProgressBar(value: progress)
                Text(YtDlpInstallModel.progressText(kind: kind, progress: progress)).font(DS.Typo.numeric(.callout)).foregroundStyle(.secondary)
            }
        case .succeeded(let outcome):
            InlineMessage(YtDlpInstallModel.successText(outcome), tone: .success)
        case .failed(let message):
            InlineMessage(message, tone: .error, detail: L("Nothing was installed. You can try again.", "Ничего не установлено. Можно повторить."))
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            switch phase {
            case .succeeded:
                Button(L("Continue", "Продолжить"), action: onContinue).keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            case .working:
                Button(L("Cancel", "Отмена"), action: onCancel).keyboardShortcut(.cancelAction).secondaryButtonLook()
            case .idle, .failed:
                Button(L("Not Now", "Не сейчас"), action: onCancel).keyboardShortcut(.cancelAction).secondaryButtonLook()
                Button(phase == .idle ? L("Install yt-dlp", "Установить yt-dlp") : L("Try Again", "Повторить"), action: onInstall)
                    .keyboardShortcut(.defaultAction).buttonStyle(.brandProminent)
            }
        }
    }
}
