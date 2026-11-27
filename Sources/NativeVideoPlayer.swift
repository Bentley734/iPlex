import SwiftUI
#if os(macOS)
import VLCKit
#elseif os(iOS)
import MobileVLCKit
#elseif os(tvOS)
import TVVLCKit
#endif

struct NativeVideoPlayer: View {
    let url: URL
    let startAt: Double
    let progress: (Double, Bool) -> Void
    let fallback: (Double) -> Void

    @State private var player = VLCMediaPlayer(options: ["--quiet", "--no-interact"])
    @State private var current = 0.0
    @State private var duration = 0.0
    @State private var seekable = false
    @State private var playing = false
    @State private var ready = false
    @State private var ended = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0

    var body: some View {
        VStack(spacing: 8) {
            VideoDrawable(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if !ready { ProgressView("Opening video…").allowsHitTesting(false) }
                }
            HStack(spacing: 14) {
                Button("Back 10 seconds", systemImage: "gobackward.10") { seek(current - 10) }
                    .labelStyle(.iconOnly).disabled(!seekable)
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill", action: toggle)
                    .labelStyle(.iconOnly).disabled(!ready)
                Button("Forward 10 seconds", systemImage: "goforward.10") { seek(current + 10) }
                    .labelStyle(.iconOnly).disabled(!seekable)
                Text(time(current)).monospacedDigit()
                #if os(tvOS)
                ProgressView(value: min(current, duration), total: max(duration, 1))
                #else
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(current, max(duration, 1)) },
                                      set: { scrubPosition = $0; if !scrubbing { seek($0) } }),
                       in: 0...max(duration, 1)) { Text("Playback position") }
                onEditingChanged: { editing in
                    if editing { scrubPosition = current }
                    else { seek(scrubPosition) }
                    scrubbing = editing
                }.disabled(!seekable || duration <= 0)
                #endif
                Text(time(duration)).monospacedDigit()
                Button("Use Compatibility Mode") { fallback(current) }
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        #if os(tvOS)
        .onPlayPauseCommand(perform: toggle)
        #endif
        .task(id: url) { await play() }
        .onDisappear {
            if ready { progress(current, ended) }
            player.stop()
            player.media = nil
        }
    }

    private func play() async {
        player.media = VLCMedia(url: url)
        player.play()
        let start = ContinuousClock.now
        var lastReport = start
        var awaitingSeek = startAt >= 5
        while !Task.isCancelled {
            let elapsed = Double(player.time.value?.intValue ?? 0) / 1_000
            playing = player.isPlaying
            if playing || (elapsed > 0 && player.hasVideoOut) { ready = true }
            switch player.state {
            case .playing, .paused: ready = true
            case .ended:
                if !ended { progress(current, true) }
                ended = true
            case .error:
                fallback(current)
                return
            default: break
            }
            if elapsed > 0 || (!ended && ready) { current = max(0, elapsed) }
            let length = Double(player.media?.length.value?.intValue ?? 0) / 1_000
            if length > 0 { duration = length }
            seekable = player.isSeekable
            if awaitingSeek, ready, seekable, duration > 0 {
                awaitingSeek = false
                if startAt < duration { seek(startAt) }
            }
            if ready, !awaitingSeek, !ended, ContinuousClock.now - lastReport >= .seconds(5) {
                lastReport = ContinuousClock.now
                progress(current, false)
            }
            if !ready && ContinuousClock.now - start > .seconds(30) {
                fallback(current)
                return
            }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
        }
    }

    private func toggle() {
        guard ready else { return }
        if playing { player.pause() }
        else {
            if ended {
                player.media = VLCMedia(url: url)
                ended = false
                current = 0
            }
            player.play()
        }
    }

    private func seek(_ seconds: Double) {
        guard seekable else { return }
        current = min(max(0, seconds), max(duration, 0))
        player.time = VLCTime(int: Int32(clamping: Int(current * 1_000)))
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if os(macOS)
private struct VideoDrawable: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = VLCVideoView()
        player.drawable = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func makeCoordinator() -> VLCMediaPlayer { player }

    static func dismantleNSView(_ view: NSView, coordinator: VLCMediaPlayer) {
        if coordinator.drawable as? NSView === view { coordinator.drawable = nil }
    }
}
#else
private struct VideoDrawable: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    func makeCoordinator() -> VLCMediaPlayer { player }

    static func dismantleUIView(_ view: UIView, coordinator: VLCMediaPlayer) {
        if coordinator.drawable as? UIView === view { coordinator.drawable = nil }
    }
}
#endif
