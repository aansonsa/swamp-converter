import SwiftUI

/// "Add a Link": paste the address of a page with a video or a song. The link joins this Studio window as a source; its download options appear on the right and Start
/// downloads it (the first time, the Studio offers to install yt-dlp).
struct StudioLinkSheet: View {
    @ObservedObject var model: StudioWindowModel
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(L("Add a Link", "Добавить ссылку")).font(DS.Typo.headline)
            Text(L("Paste the address of a page with a video or a song (YouTube, Vimeo, SoundCloud and many more). You choose the quality on the right, then press Start.",
                   "Вставьте адрес страницы с видео или песней (YouTube, Vimeo, SoundCloud и многие другие). Качество выбирается справа, затем нажмите «Начать»."))
                .font(DS.Typo.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L("https://…", "https://…"), text: Binding(get: { model.linkDraft ?? "" }, set: { model.linkDraft = $0; problem = nil }))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
                .accessibilityLabel(Text(L("Link", "Ссылка")))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(DS.Typo.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "Отмена"), role: .cancel) { model.linkDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add", "Добавить"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled((model.linkDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func add() {
        if let reason = model.commitLink() { problem = reason.message.text }
    }
}
