import SwiftUI

/// A static look-alike of the studio-core inspector, used ONLY in the window's snapshots when the session has no real schema (the form itself is studio-core's and has its own
/// snapshots). It uses the same native controls (Form .grouped, pickers, a slider, toggles) and the same summary chips, so the layout of the three columns can be judged.
struct StudioSnapshotInspector: View {
    var kind: StudioContentKind
    @State private var density = 0
    @State private var page = 1
    @State private var quality = 0.62
    @State private var faststart = true
    @State private var container = "mp4"

    private var pages: [(String, String)] {
        switch kind {
        case .video: return [("shippingbox", "Format"), ("film", "Video"), ("crop", "Picture"), ("camera.filters", "Filters"), ("speaker.wave.2", "Audio"), ("captions.bubble", "Subtitles")]
        case .audio: return [("waveform", "Audio"), ("scissors", "Trim"), ("tag", "Tags")]
        case .image: return [("photo", "Image"), ("crop", "Size"), ("paintpalette", "Colour")]
        default: return [("doc", "Options"), ("folder", "Output")]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                StudioWrapLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xs) {
                    InfoChip("MP4", emphasized: true); InfoChip("HEVC"); InfoChip("1080p30"); InfoChip("AAC 160")
                }
                Text(L("About 412 MB (68% smaller), about 6 min", "Около 412 МБ (меньше на 68 %), около 6 мин")).font(DS.Typo.callout.weight(.medium))
                Text(L("Estimate from a sample of your file", "Оценка по фрагменту вашего файла")).font(DS.Typo.caption).foregroundStyle(.secondary)
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Surface.control)
            Divider()
            Picker("", selection: $density) {
                Text(L("Simple", "Простой")).tag(0)
                Text(L("Advanced", "Расширенный")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, DS.Space.lg).padding(.top, DS.Space.md)
            HStack(spacing: DS.Space.xs) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    Image(systemName: p.0).symbolRenderingMode(.hierarchical).frame(width: 30, height: 26)
                        .background(i == page ? Brand.pink.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .foregroundStyle(i == page ? Brand.pinkInk : .secondary)
                }
            }
            .padding(.vertical, DS.Space.sm)
            Form {
                Section(L("Format", "Формат")) {
                    Picker(L("Container", "Контейнер"), selection: $container) { Text("MP4").tag("mp4"); Text("MOV").tag("mov"); Text("MKV").tag("mkv") }
                    Toggle(L("Optimize for streaming", "Оптимизировать для потоковой передачи"), isOn: $faststart)
                }
                Section(L("Quality", "Качество")) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack { Text(L("Quality", "Качество")); Spacer(); InfoChip(L("Quick recipe", "Быстрый рецепт"), emphasized: true) }
                        Slider(value: $quality)
                        HStack {
                            Text(L("Smaller file", "Меньше файл")).font(DS.Typo.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(L("Better quality", "Лучше качество")).font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .background(DS.Surface.window)
    }
}
