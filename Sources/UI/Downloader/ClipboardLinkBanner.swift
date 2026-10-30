import SwiftUI

/// The one-time "clipboard link" banner inside the sheet. The pasteboard has no change notification and this app uses no timers, so it is read ONCE when the sheet opens
/// (`ClipboardLinkReader.link()`); this view only shows what was found. "Use Link" fills the field and fetches; the close button hides the banner for this opening.
struct ClipboardLinkBanner: View {
    var link: LinkItem
    var onUse: () -> Void
    var onDismiss: (() -> Void)?

    init(link: LinkItem, onUse: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.link = link; self.onUse = onUse; self.onDismiss = onDismiss
    }

    var body: some View {
        InlineMessage(L("There is a link on the clipboard: \(link.host)", "В буфере обмена есть ссылка: \(link.host)"),
                      tone: .info, detail: Self.shortAddress(link.url),
                      fixTitle: L("Use Link", "Использовать ссылку"), onFix: onUse, onDismiss: onDismiss)
    }

    /// The address without the scheme, cut in the middle when long.
    static func shortAddress(_ url: URL, limit: Int = 64) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count); break }
        if s.count <= limit { return s }
        let head = s.prefix(limit * 2 / 3), tail = s.suffix(limit / 3 - 1)
        return head + "\u{2026}" + tail
    }
}
