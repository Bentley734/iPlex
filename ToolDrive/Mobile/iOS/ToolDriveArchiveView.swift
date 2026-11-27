import SwiftUI

public struct ToolDriveArchiveView: View {
    private let appearance: IPlexArchiveAppearance
    private let transport: ToolDriveTransport
    private let pauseOutsidePlayback: () -> Void
    private let plexSettings: () -> AnyView

    public init(title: String, text: Color, accent: Color, tint: Color?, density: Double,
                transport: ToolDriveTransport, pauseOutsidePlayback: @escaping () -> Void,
                plexSettings: @escaping () -> AnyView) {
        self.transport = transport
        archive = transport.catalog
        appearance = IPlexArchiveAppearance(title: title, text: text, accent: accent, tint: tint, density: density)
        self.pauseOutsidePlayback = pauseOutsidePlayback
        self.plexSettings = plexSettings
    }
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var archive: ArchiveStore
    @StateObject private var audio = AudioPlayer()
    @StateObject private var library = MobileLibrary()
    @StateObject private var plex = MobilePlex()

    public var body: some View {
        CatalogView()
            .environmentObject(archive)
            .environmentObject(audio)
            .environmentObject(library)
            .environmentObject(plex)
            .environment(\.iplexPlexSettings, plexSettings)
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
            .onAppear { transport.attach(audio) }
            .onDisappear {
                transport.detach(audio)
                audio.pause()
                audio.saveProgress(force: true)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { audio.saveProgress(force: true) }
            }
    }
}
