import SwiftUI

/// Title, channel, duration, thumbnail and the chips of the best quality the page offers ("4K", "60 fps", "AV1", "HDR"). For a list: the count and the channel.
///
/// The picture: the app never fetches a thumbnail itself (the only network use is yt-dlp, after consent). A local thumbnail file (for example one yt-dlp already wrote) is shown
/// through the shared `ThumbnailView`; a remote address shows the symbol tile instead, so the card has the same shape either way and nothing leaves the Mac.
struct DownloadInfoCard: View {
    var info: DownloadInfo

    private static let thumbWidth: CGFloat = 128
    private static let thumbHeight: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            thumbnail
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(info.title).font(DS.Typo.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let meta = metaLine { Text(meta).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                FlowLayout { ForEach(chips, id: \.self) { InfoChip($0) } }
                    .padding(.top, DS.Space.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = info.thumbnail, url.isFileURL {
            ThumbnailView(url: url, kind: .video, width: Self.thumbWidth, height: Self.thumbHeight, label: info.title)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.primary.opacity(0.06))
                Image(systemName: info.isPlaylist ? "rectangle.stack" : (info.formats.allSatisfy(\.isAudioOnly) && !info.formats.isEmpty ? "waveform" : "play.rectangle"))
                    .font(.system(size: 26, weight: DS.symbolWeight)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            }
            .frame(width: Self.thumbWidth, height: Self.thumbHeight)
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
            .accessibilityHidden(true)
        }
    }

    /// "Swamp Films  ·  10:12" (a list: "Swamp Films  ·  4 videos").
    var metaLine: String? {
        var parts: [String] = []
        if let channel = info.channel, !channel.isEmpty { parts.append(channel) }
        if info.isPlaylist { parts.append(DownloadFormatText.videoCount(info.entries.count)) }
        else if let d = DownloadFormatText.duration(info.duration) { parts.append(d) }
        return parts.isEmpty ? nil : parts.joined(separator: "  \u{00B7}  ")
    }

    var chips: [String] {
        var out: [String] = []
        if info.isPlaylist { out.append(L("List", "Список")) } else { out.append(contentsOf: DownloadFormatText.bestChips(for: info)) }
        if let site = Self.siteName(info) { out.append(site) }
        return out
    }

    /// "YouTube" from the extractor id; the host of the page otherwise.
    static func siteName(_ info: DownloadInfo) -> String? {
        if let e = info.extractor, !e.isEmpty {
            let base = e.split(separator: ":").first.map(String.init) ?? e
            if base.lowercased().hasPrefix("youtube") { return "YouTube" }
            return base.prefix(1).uppercased() + base.dropFirst()
        }
        return LinkParsing.displayHost(of: info.webpageURL)
    }
}
