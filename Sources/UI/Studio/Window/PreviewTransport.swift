import SwiftUI
import AVFoundation
import AppKit

// Playback for the video and audio preview. Space plays the ORIGINAL, J / K / L and the arrow keys move the playhead, I / O set In / Out. AVFoundation is touched only when a
// video or audio source is shown and playable; nothing runs while paused: the time observer (10 Hz) exists only during playback and is removed on pause.

@MainActor
final class PreviewTransport: ObservableObject {
    enum Mode: Equatable {
        /// Still frames: the before / after pair at the playhead.
        case compare
        /// The original is playing.
        case player
        /// A rendered 3 s test clip loops.
        case test
    }

    @Published private(set) var mode: Mode = .compare
    @Published private(set) var isPlaying = false
    /// The playhead in seconds. Scrubbing writes it; playback follows the player.
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var canPlay = false
    @Published private(set) var playbackNote: String?
    @Published private(set) var testClip: URL?

    private(set) var fps: Double?
    private(set) var sourceURL: URL?
    private(set) var isVideo = false
    private(set) var player: AVPlayer?
    private var sourceItem: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// Written by the timeline: In / Out set at the playhead go into the options.
    var onSetIn: ((Double) -> Void)?
    var onSetOut: ((Double) -> Void)?
    /// Called when playback pauses or the playhead is moved by a key: the pane asks the session for the frame at this time.
    var onTimeSettled: ((Double) -> Void)?

    // MARK: Loading

    func load(url: URL, duration: Double?, fps: Double?, isVideo: Bool) async {
        if sourceURL == url, self.isVideo == isVideo, (player != nil || playbackNote != nil) {
            self.duration = duration ?? self.duration; self.fps = fps; return
        }
        stop()
        sourceURL = url
        self.isVideo = isVideo
        self.duration = max(duration ?? 0, 0)
        self.fps = fps
        time = 0
        testClip = nil
        canPlay = false
        playbackNote = nil
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        guard sourceURL == url else { return }
        if playable {
            if self.duration <= 0, let d = try? await asset.load(.duration), d.seconds.isFinite { self.duration = d.seconds }
            let item = AVPlayerItem(asset: asset)
            sourceItem = item
            player = AVPlayer(playerItem: item)
            canPlay = true
        } else {
            playbackNote = L("macOS can’t play this format. The preview frames still work.", "macOS не воспроизводит этот формат. Кадры предпросмотра по-прежнему работают.")
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard canPlay, let player else { return }
        if mode == .compare { mode = isVideo ? .player : .compare }
        if mode != .test {
            let start = (duration > 0 && time >= duration - 0.05) ? 0 : time
            time = start
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        addObservers(to: player)
        isPlaying = true
        player.play()
    }

    func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        removeTimeObserver()
        isPlaying = false
        if mode == .player { time = max(0, player.currentTime().seconds); mode = .compare; onTimeSettled?(time) }
    }

    /// Stops everything (a new source, the preview leaves the screen, the window closes). The source is forgotten too, so coming back to the same file builds a new
    /// player: keeping it made `load` return early with no player, and Play did nothing after a visit to the Queue.
    func stop() {
        player?.pause()
        teardown()
        isPlaying = false
        mode = .compare
        player = nil
        sourceItem = nil
        sourceURL = nil
        canPlay = false
        testClip = nil
    }

    func seek(to t: Double, settled: Bool = false) {
        let clamped = duration > 0 ? min(max(t, 0), duration) : max(t, 0)
        time = clamped
        if mode == .test { return }
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if settled { onTimeSettled?(clamped) }
    }

    func step(forward: Bool, coarse: Bool) {
        if isPlaying { pause() }
        let t = PreviewMath.step(time, forward: forward, fps: fps, coarse: coarse, duration: duration)
        seek(to: t, settled: true)
    }

    /// J / K / L like an editor: J back a second, K pause, L forward a second.
    func shuttle(_ key: Character) {
        switch key {
        case "k": pause()
        case "j": step(forward: false, coarse: true)
        case "l": step(forward: true, coarse: true)
        default: break
        }
    }

    func setIn() { onSetIn?(PreviewMath.snappedToFrame(time, fps: fps)) }
    func setOut() { onSetOut?(PreviewMath.snappedToFrame(time, fps: fps)) }

    // MARK: Test clip

    /// Loops a rendered clip in place of the original.
    func playTest(clip: URL) {
        player?.pause()
        removeTimeObserver()
        testClip = clip
        mode = .test
        let p = player ?? AVPlayer()
        player = p
        p.replaceCurrentItem(with: AVPlayerItem(url: clip))
        canPlay = true
        addObservers(to: p)
        isPlaying = true
        p.seek(to: .zero)
        p.play()
    }

    func closeTest() {
        guard mode == .test else { return }
        player?.pause()
        removeTimeObserver()
        removeEndObserver()
        testClip = nil
        mode = .compare
        isPlaying = false
        player?.replaceCurrentItem(with: sourceItem)
    }

    // MARK: Observers

    private func addObservers(to player: AVPlayer) {
        removeTimeObserver()
        if mode != .test {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { if let self, self.mode != .test, t.seconds.isFinite { self.time = t.seconds } }
            }
        }
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
    }

    private func reachedEnd() {
        guard let player else { return }
        if mode == .test {
            player.seek(to: .zero)
            player.play()
        } else {
            isPlaying = false
            removeTimeObserver()
            if mode == .player { mode = .compare }
            time = duration
            onTimeSettled?(time)
        }
    }

    private func removeTimeObserver() {
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
    }

    private func removeEndObserver() {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    private func teardown() {
        removeTimeObserver()
        removeEndObserver()
    }
}

/// The video layer of the player (the original while it plays, the test clip while it loops).
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer?

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { return nil }
        override func layout() { super.layout(); playerLayer.frame = bounds }
    }

    func makeNSView(context: Context) -> LayerView { LayerView() }
    func updateNSView(_ view: LayerView, context: Context) { if view.playerLayer.player !== player { view.playerLayer.player = player } }
}
