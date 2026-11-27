import SwiftUI

struct MobileVisualizerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualizerPreset") private var savedPreset = TVVisualizerPreset.mirroredStage.rawValue
    private var preset: TVVisualizerPreset { TVVisualizerPreset(rawValue: savedPreset) ?? .mirroredStage }
    private var animating: Bool { player.phase == .playing && !reduceMotion && scene == .active }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { _ in
                    TVKaleidoscopeSurface(preset: preset, time: reduceMotion ? 0 : player.visualizerPosition,
                                         levels: animating ? player.visualizerLevels() : [0, 0, 0],
                                         moving: animating, reduceMotion: reduceMotion)
                }
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    ArchiveScrollingTitle(player.currentTrack?.title ?? player.collection).font(.headline)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 34) {
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Previous track").disabled(player.tracks.isEmpty)
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                        }.accessibilityLabel(player.isPlaying ? "Pause" : "Play").disabled(!player.canToggle)
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Next track").disabled(player.index + 1 >= player.tracks.count)
                    }.font(.title3)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: 580)
                .archiveControl()
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Visualizer").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Visualizer", selection: Binding(get: { preset }, set: { savedPreset = $0.rawValue })) {
                            ForEach(TVVisualizerPreset.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Label("Choose visualizer", systemImage: "sparkles") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onChange(of: animating, initial: true) { _, active in player.setVisualizerActive(active) }
        .onDisappear { player.setVisualizerActive(false) }
    }
}
