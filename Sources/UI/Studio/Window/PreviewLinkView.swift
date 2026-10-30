import SwiftUI
import AppKit

/// The download target's preview: the link as it was given and, after an explicit "Get Info" (the only network call of this view), the info card of the download module.
/// Nothing is fetched on its own: the downloader asks for consent first, and says so when it was not given.
struct PreviewLinkView: View {
    var row: StudioSourceRow
    var source: StudioSource?

    @State private var info: DownloadInfo?
    @State private var loading = false
    @State private var error: String?

    private var link: LinkItem? { source?.input.link }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "link").symbolRenderingMode(.hierarchical).font(.title2).foregroundStyle(Brand.blueInk).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(link?.displayTitle ?? row.name).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                        Text(link?.url.absoluteString ?? "").font(DS.Typo.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                if let info {
                    DownloadInfoCard(info: info)
                } else {
                    HStack(spacing: DS.Space.md) {
                        Button { Task { await fetch() } } label: { Label(L("Get Info", "Получить сведения"), systemImage: "info.circle") }
                            .secondaryButtonLook()
                            .disabled(loading || link == nil)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    Text(L("This contacts the site to read the title, the length and the available qualities. Nothing is downloaded yet.",
                           "Приложение обратится к сайту, чтобы узнать название, длину и доступные качества. Пока ничего не скачивается."))
                        .font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error { InlineMessage(error, tone: .warning, onDismiss: { self.error = nil }) }
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: row.id) { info = nil; error = nil }
    }

    private func fetch() async {
        guard let url = link?.url else { return }
        loading = true; error = nil
        do { info = try await DownloadService.shared.fetchInfo(url) }
        catch is CancellationError { }
        catch { self.error = ConversionError.describe(error) }
        loading = false
    }
}
