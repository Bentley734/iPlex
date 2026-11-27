import SwiftUI

public struct ToolDriveArchiveView: View {
    private let appearance: IPlexArchiveAppearance
    private let pauseOutsidePlayback: () -> Void

    public init(title: String, text: Color, accent: Color, tint: Color?, density: Double,
                pauseOutsidePlayback: @escaping () -> Void) {
        appearance = IPlexArchiveAppearance(title: title, text: text, accent: accent, tint: tint, density: density)
        self.pauseOutsidePlayback = pauseOutsidePlayback
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var archive = ArchiveStore()
    @StateObject private var audio = AudioPlayer()
    @StateObject private var library = MobileLibrary()
    @StateObject private var plex = MobilePlex()

    public var body: some View {
        CatalogView()
            .environmentObject(archive)
            .environmentObject(audio)
            .environmentObject(library)
            .environmentObject(plex)
            .environment(\.iplexArchiveAppearance, appearance)
            .environment(\.mobileTheme, .liquidGlass)
            .environment(\.mobileGlassControls, true)
            .environment(\.archiveAccent, appearance.accent)
            .environment(\.glassOpacity, GlassOpacity(Int(appearance.density * 100)))

            .tint(appearance.accent)
            .task {
                    audio.onShowCompleted = { [weak archive] id in archive?.markListened(id) }
                    await archive.load()
                }
            .onChange(of: audio.phase) { _, phase in
                if phase == .playing { pauseOutsidePlayback() }
            }
            .onDisappear { audio.pause(); audio.saveProgress(force: true) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { audio.saveProgress(force: true) }
            }
    }
}
