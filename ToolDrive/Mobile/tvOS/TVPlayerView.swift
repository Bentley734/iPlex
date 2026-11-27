import SwiftUI

struct TVPlayerView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var equalizer = false
    @State private var visualizer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Now Playing").font(.title.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack(alignment: .top, spacing: 52) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        TVArtworkHeader(title: player.collection, subtitle: player.context)
                            .frame(minHeight: 235)
                        if let track = player.currentTrack {
                            Text("Track \(player.index + 1) of \(player.tracks.count)").font(.caption).foregroundStyle(archive.resolvedAccent)
                            ArchiveScrollingTitle(track.title).font(.title3.bold())
                        }
                        if let error = player.errorMessage {
                            Text(error).font(.callout).foregroundStyle(archive.theme.muted)
                        } else if player.phase == .resolving || player.phase == .buffering {
                            ProgressView(player.phase == .resolving ? "Finding recording" : "Buffering")
                        }
                        if player.duration > 0 {
                            ProgressView(value: min(max(0, player.elapsed), player.duration), total: player.duration)
                                .accessibilityLabel("Playback position")
                            HStack {
                                Text(time(player.elapsed))
                                Spacer()
                                Text(time(player.duration))
                            }.font(.caption.monospacedDigit())
                        }
                        HStack(spacing: 18) {
                            transport("Previous track", "backward.end.fill", action: player.previous)
                                .disabled(player.tracks.isEmpty)
                            transport("Back 15 seconds", "gobackward.15") { player.seek(to: player.elapsed - 15) }
                                .disabled(player.duration <= 0)
                            transport(player.phase == .failed ? "Retry" : (player.isPlaying ? "Pause" : "Play"),
                                      player.phase == .failed ? "arrow.clockwise" : (player.isPlaying ? "pause.fill" : "play.fill"),
                                      action: player.toggle)
                                .accessibilityIdentifier("tv.transport").disabled(!player.canToggle)
                            transport("Forward 15 seconds", "goforward.15") { player.seek(to: player.elapsed + 15) }
                                .disabled(player.duration <= 0)
                            transport("Next track", "forward.end.fill", action: player.next)
                                .disabled(player.index + 1 >= player.tracks.count)
                        }.padding(16).archiveControl().focusSection()
                        HStack(spacing: 18) {
                            Button("Equalizer") { equalizer = true }
                            Button("Visualizer") { visualizer = true }
                                .accessibilityIdentifier("tv.visualizer")
                            Button("Stop") { player.stop(); dismiss() }
                        }
                    }.padding(15)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Tracklist").font(.title3.bold())
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(player.tracks) { track in
                                Button { player.selectTrack(track.id) } label: {
                                    HStack(spacing: 16) {
                                        Text(String(format: "%02d", track.id + 1)).font(.caption.monospacedDigit())
                                        ArchiveScrollingTitle(track.title, active: track.id == player.index, restingLines: 2).font(.headline)
                                        Spacer()
                                        if track.id == player.index { Image(systemName: "waveform") }
                                        if let duration = track.duration { Text(time(duration)).font(.caption.monospacedDigit()) }
                                    }
                                    .padding(18).foregroundStyle(track.id == player.index ? archive.resolvedAccent : archive.theme.text)
                                    .archivePanel()
                                }.buttonStyle(.card)
                                .accessibilityAddTraits(track.id == player.index ? .isSelected : [])
                            }
                        }.padding(12)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            }
        }.padding(40)
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .onExitCommand { dismiss() }
        .fullScreenCover(isPresented: $equalizer) { TVEqualizerView() }
        .fullScreenCover(isPresented: $visualizer) { TVVisualizerView() }
    }

    private func transport(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 36, minHeight: 38) }
            .accessibilityLabel(label)
    }

    private func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TVEqualizerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack {
                Text("Equalizer").font(.largeTitle.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                Button("Flat") { player.setEqualizer(.flat) }
                preset("Bass Boost", bass: 8, mid: 0, treble: 2)
                preset("Vocal", bass: -3, mid: 6, treble: 1)
                preset("Bright", bass: -1, mid: 1, treble: 7)
            }
            VStack(spacing: 20) {
                band("Bass", \.bass)
                band("Mid", \.mid).disabled(player.equalizer.magik)
                band("Treble", \.treble)
            }.padding(24).archivePanel()
            Button {
                var next = player.equalizer
                next.magik.toggle()
                player.setEqualizer(next)
            } label: {
                Label("Magik", systemImage: player.equalizer.magik ? "checkmark.circle.fill" : "circle")
            }.accessibilityAddTraits(player.equalizer.magik ? .isSelected : [])
            if player.equalizerAvailable == false { Text("This track or output doesn’t support equalization.").font(.callout) }
        }
        .padding(55).buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .onExitCommand { dismiss() }
    }

    private func preset(_ name: String, bass: Double, mid: Double, treble: Double) -> some View {
        Button(name) { player.setEqualizer(PlaybackEQSettings(bass: bass, mid: mid, treble: treble, magik: player.equalizer.magik)) }
    }

    private func band(_ title: String, _ band: WritableKeyPath<PlaybackEQSettings, Double>) -> some View {
        let value = player.equalizer[keyPath: band]
        return HStack {
            Text(title).font(.headline)
            Spacer()
            Button {
                var next = player.equalizer
                next[keyPath: band] = max(-10, value - 1)
                player.setEqualizer(next)
            } label: { Image(systemName: "minus") }.disabled(value <= -10).accessibilityLabel("Decrease " + title)
            Text(String(format: "%+.0f dB", value)).font(.body.monospacedDigit()).frame(width: 125)
            Button {
                var next = player.equalizer
                next[keyPath: band] = min(10, value + 1)
                player.setEqualizer(next)
            } label: { Image(systemName: "plus") }.disabled(value >= 10).accessibilityLabel("Increase " + title)
        }
    }
}

private struct TVVisualizerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualizerPreset") private var selection = TVVisualizerPreset.mirroredStage.rawValue
    @State private var choosingPreset = false
    private var moving: Bool { scene == .active && !reduceMotion && player.phase == .playing }
    private var preset: TVVisualizerPreset { TVVisualizerPreset(rawValue: selection) ?? .mirroredStage }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            artwork.ignoresSafeArea().accessibilityHidden(true)
            HStack(spacing: 24) {
                ArchiveScrollingTitle(player.currentTrack?.title ?? player.collection).font(.headline)
                Spacer(minLength: 12)
                Button {
                    choosingPreset = true
                } label: {
                    Label(preset.title, systemImage: "sparkles")
                }
                .accessibilityHint("Choose a visualizer")
                .accessibilityIdentifier("tv.visualizer.preset")
                .tint(archive.resolvedAccent)
                .confirmationDialog("Choose a visualizer", isPresented: $choosingPreset) {
                    ForEach(TVVisualizerPreset.allCases) { style in
                        Button(style.title) { selection = style.rawValue }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .tint(nil)
                Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }.disabled(!player.canToggle)
                Button("Done") { dismiss() }.accessibilityIdentifier("tv.visualizer.done")
            }
            .padding(20).archiveControl().padding(36)
        }
        .buttonStyle(TVActionStyle())
        .onPlayPauseCommand { if player.canToggle { player.toggle() } }
        .onChange(of: moving, initial: true) { _, active in player.setVisualizerActive(active) }
        .onDisappear { player.setVisualizerActive(false) }
    }

    private var artwork: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { _ in
            TVKaleidoscopeSurface(preset: preset, time: reduceMotion ? 0 : player.visualizerPosition,
                                  levels: moving ? player.visualizerLevels() : [0, 0, 0],
                                  moving: moving, reduceMotion: reduceMotion)
        }
    }
}
