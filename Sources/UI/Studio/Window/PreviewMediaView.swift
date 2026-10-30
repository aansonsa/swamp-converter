import SwiftUI
import AppKit

// Video and audio preview. Video: the frame at the playhead before / after, playback of the original on Space, crop handles, safe areas, a filmstrip timeline with In / Out handles and
// the "Render 3 s Test" loop. Audio: the waveform with In / Out handles and the loudness of the file. In / Out go straight into the trim fields of the options.

struct PreviewMediaView: View {
    @ObservedObject var model: StudioWindowModel
    @ObservedObject var session: StudioSession
    @ObservedObject private var transport: PreviewTransport
    var row: StudioSourceRow
    var frames: PreviewFrames
    var bindings: PreviewBindings
    var appliesToFocus: Bool

    @StateObject private var renderer = PreviewClipRenderer()
    @State private var divider = 0.5
    @State private var zoom = PreviewZoom.fit
    @State private var loupe = false
    @State private var cropEditing = false
    @State private var dragInsets: PreviewMath.CropInsets?
    @State private var safeAreaIndex: Int?
    @State private var frame: CGImage?
    @State private var filmstrip: [CGImage] = []
    @State private var overview: AudioOverview?
    @State private var keyframes: [Double] = []
    @State private var showKeyframes = false
    @State private var widthBucket = 1024
    @State private var scrubTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(model: StudioWindowModel, session: StudioSession, row: StudioSourceRow, frames: PreviewFrames, bindings: PreviewBindings, appliesToFocus: Bool) {
        self.model = model; self.session = session; self.transport = model.transport
        self.row = row; self.frames = frames; self.bindings = bindings; self.appliesToFocus = appliesToFocus
    }

    private var isVideo: Bool { row.kind == .video }
    private var duration: Double { max(row.duration ?? transport.duration, 0) }
    private var values: OptionValues { session.resolved?.values ?? session.values }
    private var trimStart: Double { bindings.trimStartKey.map { max(values.time($0), 0) } ?? 0 }
    private var trimEnd: Double? { bindings.trimEndKey.flatMap { k in values[k] == nil ? nil : (values.time(k) > 0 ? values.time(k) : nil) } }
    private var sourcePixels: CGSize { row.pixelSize ?? frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    private var liveInsets: PreviewMath.CropInsets? { PreviewCropAdapter.insets(.video, values: values, source: sourcePixels) }
    private var file: FileItem? { session.sources.first { $0.id == row.id }?.input.file }
    private var chapters: [Double] {
        (session.sources.first { $0.id == row.id }?.info?.streams(of: .chapter) ?? []).compactMap { $0.facts["start"]?.asDouble }
    }

    private struct LoadKey: Equatable { var url: URL?; var duration: Double }

    var body: some View {
        VStack(spacing: 0) {
            if isVideo { videoStage } else { audioStage }
            Divider()
            StudioTransportBar(transport: transport, canTrim: bindings.hasTrim)
            StudioTimeline(duration: max(duration, 0.001), time: transport.time, start: trimStart, end: trimEnd,
                           backdrop: isVideo ? .filmstrip(filmstrip) : .waveform(overview?.peaks ?? []),
                           chapters: chapters, keyframes: showKeyframes ? keyframes : [], fps: row.fps, canTrim: bindings.hasTrim,
                           onScrub: { scrub($0, final: $1) }, onTrim: trim)
                .frame(height: 52)
                .padding(.horizontal, DS.Space.lg)
            controls
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { transport.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { transport.step(forward: false, coarse: false); return .handled }
        .onKeyPress(.rightArrow) { transport.step(forward: true, coarse: false); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkloiJKLOI")) { press in
            switch press.characters.lowercased() {
            case "i": transport.setIn()
            case "o": transport.setOut()
            default: if let c = press.characters.lowercased().first { transport.shuttle(c) }
            }
            return .handled
        }
        .task(id: LoadKey(url: row.url, duration: duration)) { await load() }
        .task(id: Self.RequestKey(id: row.id, bucket: widthBucket, applies: appliesToFocus)) { requestFrame(transport.time) }
        .onChange(of: renderer.state) { _, new in if case .ready(let url) = new { transport.playTest(clip: url) } }
        .onAppear {
            focused = true
            installTransportCallbacks()
        }
        // The callbacks capture this view's values (the row, its trim): renew them when another file is shown, or In / Out and the frames went to the first file.
        .onChange(of: row.id) { _, _ in installTransportCallbacks() }
        .onDisappear {
            scrubTask?.cancel()
            // Drop the closures: they hold this view and, through it, the window's model (a closed Studio stayed in memory).
            transport.onSetIn = nil; transport.onSetOut = nil; transport.onTimeSettled = nil
            transport.stop()
            renderer.cleanUp()
            session.cancelPreview()
        }
    }

    private struct RequestKey: Equatable { var id: String; var bucket: Int; var applies: Bool }

    private func installTransportCallbacks() {
        transport.onSetIn = { t in let r = PreviewMath.settingIn(at: t, currentEnd: trimEnd, duration: duration); trim(r.start, r.end) }
        transport.onSetOut = { t in let r = PreviewMath.settingOut(at: t, currentStart: trimStart, duration: duration); trim(r.start, r.end) }
        transport.onTimeSettled = { t in requestFrame(t) }
    }

    // MARK: Stages

    @ViewBuilder private var videoStage: some View {
        ZStack {
            if transport.mode != .compare, let player = transport.player {
                PlayerLayerView(player: player).background(Color.black)
            } else {
                PreviewCanvas(before: frames.before ?? frame, after: frames.after, isWorking: frames.isWorking, divider: $divider, zoom: $zoom, loupeOn: loupe, arrowKeysMoveDivider: false) { rect in
                    if cropEditing, bindings.videoCrop, sourcePixels.width > 0 {
                        CropOverlay(rect: rect, insets: Binding(get: { dragInsets ?? liveInsets ?? PreviewMath.CropInsets() }, set: { dragInsets = $0 }), sourcePixels: sourcePixels) { commitCrop($0) }
                    }
                    if let i = safeAreaIndex, PreviewMath.verticalSafeAreas.indices.contains(i) { SafeAreaOverlay(rect: rect, area: PreviewMath.verticalSafeAreas[i]) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widthBucket = PreviewImageView.bucket(forWidth: $0 * 2) }
            }
            if transport.mode == .test { testBadge }
            if let note = transport.playbackNote, transport.mode == .compare { playbackHint(note) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var audioStage: some View {
        VStack(spacing: DS.Space.md) {
            Spacer(minLength: 0)
            if let url = row.url { ThumbnailView(url: url, kind: .audio, size: 96, cornerRadius: DS.Radius.card, fit: true, label: row.name) }
            Text(row.name).font(DS.Typo.headline).lineLimit(1).truncationMode(.middle)
            loudnessReadout
            if let note = transport.playbackNote { Text(note).font(DS.Typo.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var loudnessReadout: some View {
        if let o = overview {
            StudioWrapLayout(spacing: DS.Space.sm, lineSpacing: DS.Space.sm) {
                if let l = o.integratedLUFS { InfoChip(L("Loudness \(Self.number(l)) LUFS", "Громкость \(Self.number(l)) LUFS"), symbol: "speaker.wave.2") }
                InfoChip(L("Peak \(Self.number(o.samplePeakDB)) dBFS", "Пик \(Self.number(o.samplePeakDB)) dBFS"), symbol: "waveform.path.ecg")
                InfoChip(o.channels == 1 ? L("Mono", "Моно") : L("Stereo", "Стерео"), symbol: "hifispeaker")
            }
            .frame(maxWidth: 420)
        } else {
            ProgressView().controlSize(.small).accessibilityLabel(Text(L("Measuring the loudness", "Измерение громкости")))
        }
    }

    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "\u{2212}\u{221E}" }
        return String(format: "%.1f", v).replacingOccurrences(of: "-", with: "\u{2212}").replacingOccurrences(of: ".", with: Loc.shared.language == .ru ? "," : ".")
    }

    private var testBadge: some View {
        VStack {
            HStack(spacing: DS.Space.sm) {
                InfoChip(L("3 s test with your settings", "Проба 3 с с вашими настройками"), symbol: "repeat")
                Button(L("Close Test", "Закрыть пробу")) { transport.closeTest(); renderer.cancel(); requestFrame(transport.time) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(DS.Space.sm)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playbackHint(_ text: String) -> some View {
        VStack { Spacer(); InfoChip(text, symbol: "info.circle").padding(DS.Space.sm) }.frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        PreviewControlBar {
            if isVideo {
                Picker(L("Zoom", "Масштаб"), selection: $zoom) {
                    Text(L("Fit", "Вписать")).tag(PreviewZoom.fit)
                    Text("100%").tag(PreviewZoom.actual)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                PreviewToggleButton(title: L("Loupe", "Лупа"), symbol: "plus.magnifyingglass", isOn: $loupe)
                if bindings.videoCrop { PreviewToggleButton(title: L("Crop", "Обрезка"), symbol: "crop", isOn: cropBinding) }
                if PreviewMath.offersSafeAreas(for: sourcePixels) { safeAreaMenu }
                if KeyframeScanner.isAvailable { PreviewToggleButton(title: L("Key Frames", "Ключевые кадры"), symbol: "diamond", isOn: keyframeBinding) }
                renderTestControl
                PreviewSizeChip(original: row.sizeBytes, result: frames.resultBytes)
                if let note = frames.note { Text(note).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if !appliesToFocus { InfoChip(L("The result preview follows the first file", "Просмотр результата следует за первым файлом"), symbol: "info.circle") }
            } else {
                PreviewSizeChip(original: row.sizeBytes, result: frames.resultBytes)
            }
        }
    }

    private var safeAreaMenu: some View {
        Menu {
            Button(L("Off", "Выключено")) { safeAreaIndex = nil }
            ForEach(Array(PreviewMath.verticalSafeAreas.enumerated()), id: \.offset) { i, area in
                Button { safeAreaIndex = i } label: { Label(area.name.text, systemImage: safeAreaIndex == i ? "checkmark" : "rectangle.dashed") }
            }
        } label: {
            Label(L("Safe Areas", "Безопасные зоны"), systemImage: "rectangle.dashed").font(DS.Typo.caption.weight(.medium))
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
    }

    @ViewBuilder private var renderTestControl: some View {
        switch renderer.state {
        case .rendering(let p):
            HStack(spacing: DS.Space.sm) {
                SlantedProgressBar(value: p).frame(width: 120)
                Button(L("Cancel", "Отмена")) { renderer.cancel() }.buttonStyle(.bordered).controlSize(.small)
            }
        case .failed(let message):
            InlineMessage(message, tone: .warning, fixTitle: L("Try Again", "Повторить"), onFix: { startTest() })
        default:
            Button { startTest() } label: { Label(L("Render 3 s Test", "Проба 3 с"), systemImage: "film.stack").font(DS.Typo.caption.weight(.medium)) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!bindings.hasTrim || file == nil || !appliesToFocus)
                .help(L("Encodes three seconds from the playhead with your settings and plays them in a loop.", "Кодирует три секунды от текущего места с вашими настройками и воспроизводит по кругу."))
        }
    }

    // MARK: Actions

    private func load() async {
        if let o = model.previewOverride {
            filmstrip = o.filmstrip ?? []; overview = o.overview
            if let f = o.frames?.before { frame = f }
            return
        }
        guard let url = row.url else { return }
        await transport.load(url: url, duration: row.duration, fps: row.fps, isVideo: isVideo)
        if isVideo {
            frame = nil
            frame = await PreviewFrameGrabber.frame(url: url, at: 0, maxPixel: 1280)
            if duration > 0 { filmstrip = await PreviewFrameGrabber.filmstrip(url: url, duration: duration, count: 12) }
        } else {
            overview = nil
            overview = await AudioOverviewLoader.load(url: url, duration: row.duration, channels: nil)
        }
    }

    private func scrub(_ t: Double, final: Bool) {
        transport.seek(to: t)
        guard isVideo else { return }
        scrubTask?.cancel()
        if final { requestFrame(t); return }
        scrubTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { requestFrame(t) }
        }
    }

    /// The still frame at `t`: the session's before / after pair when it follows this file, otherwise just the original.
    private func requestFrame(_ t: Double) {
        guard isVideo else { return }
        model.previewTime = t
        model.previewMaxPixel = widthBucket
        if appliesToFocus { session.requestPreview(time: t, maxPixel: widthBucket) }
        if let url = row.url {
            Task { @MainActor in
                let img = await PreviewFrameGrabber.frame(url: url, at: t, maxPixel: widthBucket)
                if !Task.isCancelled, abs(transport.time - t) < 0.5 || img != nil { frame = img ?? frame }
            }
        }
    }

    private func trim(_ start: Double, _ end: Double?) {
        guard let sk = bindings.trimStartKey, let ek = bindings.trimEndKey else { return }
        session.set(sk, start > 0.0005 ? .double(start) : nil)
        session.set(ek, end.map { .double($0) })
    }

    private func startTest() {
        guard let file else { return }
        renderer.start(base: session.recipe(), bindings: bindings, file: file, time: transport.time, duration: duration)
    }

    private var cropBinding: Binding<Bool> {
        Binding(get: { cropEditing }, set: { on in
            cropEditing = on
            if on, liveInsets == nil { for w in PreviewCropAdapter.writes(.video, insets: PreviewMath.CropInsets(), source: sourcePixels) { session.set(w.key, w.value) } }
            if !on { dragInsets = nil; session.set(PreviewCropAdapter.modeKey(.video), "none") }
        })
    }

    private func commitCrop(_ insets: PreviewMath.CropInsets) {
        for w in PreviewCropAdapter.writes(.video, insets: insets, source: sourcePixels) { session.set(w.key, w.value) }
        dragInsets = nil
    }

    private var keyframeBinding: Binding<Bool> {
        Binding(get: { showKeyframes }, set: { on in
            showKeyframes = on
            guard on, keyframes.isEmpty, let url = row.url else { return }
            Task { @MainActor in keyframes = await KeyframeScanner.scan(url: url) }
        })
    }
}
