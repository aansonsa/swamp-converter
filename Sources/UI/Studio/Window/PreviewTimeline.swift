import SwiftUI
import AppKit

// The timeline under a video or audio preview: a filmstrip or a waveform, the Swamp Blue scrub track, In / Out handles (they write the trim fields of the options), chapter marks,
// key frame ticks and the playhead. Drawing is one Canvas; the handles are real views so they take drags and VoiceOver.

enum TimelineBackdrop {
    case none
    case filmstrip([CGImage])
    case waveform([Float])
}

struct StudioTimeline: View {
    var duration: Double
    var time: Double
    /// The kept range from the options: start and end (nil end = until the end of the clip).
    var start: Double
    var end: Double?
    var backdrop: TimelineBackdrop
    var chapters: [Double] = []
    var keyframes: [Double] = []
    var fps: Double?
    var canTrim: Bool
    var onScrub: (Double, Bool) -> Void
    var onTrim: (Double, Double?) -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?
    @Environment(\.a11y) private var a11y

    private let height: CGFloat = 52
    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let kept = PreviewMath.keptFractions(start: dragStart ?? start, end: dragEnd ?? end, duration: duration)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size: size, kept: kept) }
                    .frame(width: w, height: height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { onScrub(PreviewMath.snappedToFrame(PreviewMath.time(atX: $0.location.x, width: w, duration: duration), fps: fps), false) }
                        .onEnded { onScrub(PreviewMath.snappedToFrame(PreviewMath.time(atX: $0.location.x, width: w, duration: duration), fps: fps), true) })
                if canTrim {
                    handle(isStart: true, x: CGFloat(kept.lo) * w, width: w)
                    handle(isStart: false, x: CGFloat(kept.hi) * w, width: w)
                }
            }
            .frame(width: w, height: height)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("Timeline", "Шкала времени")))
        .accessibilityValue(Text(Util.formatTime(time, fraction: true)))
        .accessibilityAdjustableAction { dir in
            let step = PreviewMath.step(time, forward: dir == .increment, fps: fps, coarse: true, duration: duration)
            onScrub(step, true)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, kept: (lo: Double, hi: Double)) {
        let track = CGRect(origin: .zero, size: size)
        let body = CGRect(x: 0, y: 0, width: size.width, height: size.height - 8)
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).path(in: body)
        ctx.fill(shape, with: .color(.primary.opacity(0.06)))
        var inner = ctx
        inner.clip(to: shape)
        switch backdrop {
        case .none: break
        case .filmstrip(let images):
            if !images.isEmpty {
                let tile = body.width / CGFloat(images.count)
                for (i, img) in images.enumerated() {
                    inner.draw(Image(decorative: img, scale: 1), in: CGRect(x: CGFloat(i) * tile, y: 0, width: tile + 0.5, height: body.height))
                }
            }
        case .waveform(let peaks):
            if !peaks.isEmpty {
                let step = body.width / CGFloat(peaks.count)
                for (i, p) in peaks.enumerated() {
                    let h = max(1.5, CGFloat(min(p, 1)) * body.height * 0.92)
                    let bar = CGRect(x: CGFloat(i) * step + 0.5, y: (body.height - h) / 2, width: max(step - 1, 1), height: h)
                    let inKept = Double(i) / Double(peaks.count) >= kept.lo && Double(i) / Double(peaks.count) <= kept.hi
                    inner.fill(Path(roundedRect: bar, cornerRadius: min(step / 2, 1.5)), with: .color(inKept ? Brand.blueFill : Color.secondary.opacity(0.5)))
                }
            }
        }
        // The part that will be cut away is dimmed.
        inner.fill(Path(CGRect(x: 0, y: 0, width: body.width * kept.lo, height: body.height)), with: .color(.black.opacity(0.42)))
        inner.fill(Path(CGRect(x: body.width * kept.hi, y: 0, width: body.width * (1 - kept.hi), height: body.height)), with: .color(.black.opacity(0.42)))
        // Chapter marks and key frames.
        for c in chapters where duration > 0 {
            let x = PreviewMath.x(forTime: c, width: body.width, duration: duration)
            inner.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: body.height)), with: .color(.white.opacity(0.85)))
        }
        for k in keyframes where duration > 0 {
            let x = PreviewMath.x(forTime: k, width: body.width, duration: duration)
            inner.fill(Path(CGRect(x: x - 0.5, y: body.height - 5, width: 1, height: 5)), with: .color(.white.opacity(0.9)))
        }
        ctx.stroke(shape, with: .color(.primary.opacity(a11y.increaseContrast ? 0.6 : 0.14)), lineWidth: a11y.increaseContrast ? 1.5 : 0.5)
        // The scrub track: Swamp Blue, filled up to the playhead.
        let trackY = size.height - 5
        let bar = CGRect(x: 0, y: trackY, width: track.width, height: 4)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.primary.opacity(0.14)))
        let px = PreviewMath.x(forTime: time, width: track.width, duration: duration)
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: trackY, width: max(px, 0), height: 4), cornerRadius: 2), with: .color(Brand.blueFill))
        // The playhead.
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height - 2)), with: .color(Brand.pink))
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: trackY - 2, width: 8, height: 8)), with: .color(Brand.pink))
    }

    // MARK: Handles

    private func handle(isStart: Bool, x: CGFloat, width: CGFloat) -> some View {
        let label = isStart ? L("Start of the kept part", "Начало сохраняемой части") : L("End of the kept part", "Конец сохраняемой части")
        let value = isStart ? (dragStart ?? start) : (dragEnd ?? end ?? duration)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Brand.blueFill)
            .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1) }
            .overlay { Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 16) }
            .frame(width: handleWidth, height: height - 8)
            .position(x: min(max(x + (isStart ? handleWidth / 2 : -handleWidth / 2), handleWidth / 2), width - handleWidth / 2), y: (height - 8) / 2)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let t = PreviewMath.snappedToFrame(PreviewMath.time(atX: v.location.x + (isStart ? -handleWidth / 2 : handleWidth / 2), width: width, duration: duration), fps: fps)
                    if isStart { let r = PreviewMath.settingIn(at: t, currentEnd: end, duration: duration); dragStart = r.start; dragEnd = r.end }
                    else { let r = PreviewMath.settingOut(at: t, currentStart: start, duration: duration); dragStart = r.start; dragEnd = r.end ?? duration }
                }
                .onEnded { _ in
                    let s = dragStart ?? start, e = dragEnd ?? end
                    dragStart = nil; dragEnd = nil
                    onTrim(s, (e ?? duration) >= duration - 0.0005 ? nil : e)
                })
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(Util.formatTime(value, fraction: true)))
            .accessibilityAdjustableAction { dir in
                let t = PreviewMath.step(value, forward: dir == .increment, fps: fps, coarse: true, duration: duration)
                if isStart { let r = PreviewMath.settingIn(at: t, currentEnd: end, duration: duration); onTrim(r.start, r.end) }
                else { let r = PreviewMath.settingOut(at: t, currentStart: start, duration: duration); onTrim(r.start, r.end) }
            }
    }
}

/// Play, step, the time read-out and In / Out buttons.
struct StudioTransportBar: View {
    @ObservedObject var transport: PreviewTransport
    var canTrim: Bool

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Button { transport.togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .disabled(!transport.canPlay)
            .help(transport.canPlay ? L("Play or pause (Space)", "Воспроизвести или остановить (пробел)") : (transport.playbackNote ?? ""))
            .accessibilityLabel(Text(transport.isPlaying ? L("Pause", "Пауза") : L("Play", "Воспроизвести")))
            Button { transport.step(forward: false, coarse: false) } label: { Image(systemName: "backward.frame").frame(width: 18, height: 18) }
                .buttonStyle(.bordered).accessibilityLabel(Text(StudioCommands.title(.stepBackward).text)).help(StudioCommands.title(.stepBackward).text)
            Button { transport.step(forward: true, coarse: false) } label: { Image(systemName: "forward.frame").frame(width: 18, height: 18) }
                .buttonStyle(.bordered).accessibilityLabel(Text(StudioCommands.title(.stepForward).text)).help(StudioCommands.title(.stepForward).text)
            Text("\(Util.formatTime(transport.time, fraction: true)) / \(Util.formatTime(transport.duration))")
                .font(DS.Typo.numeric(DS.Typo.callout)).foregroundStyle(.secondary)
                .accessibilityLabel(Text(L("Time", "Время")))
            Spacer(minLength: DS.Space.sm)
            if canTrim {
                Button { transport.setIn() } label: { Label(L("Start Here", "Начало здесь"), systemImage: "arrow.right.to.line") }
                    .buttonStyle(.bordered).controlSize(.small).help(L("Keep from here (I)", "Сохранить отсюда (I)"))
                Button { transport.setOut() } label: { Label(L("End Here", "Конец здесь"), systemImage: "arrow.left.to.line") }
                    .buttonStyle(.bordered).controlSize(.small).help(L("Keep until here (O)", "Сохранить до сюда (O)"))
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .tint(nil)
    }
}
