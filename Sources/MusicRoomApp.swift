#if os(macOS)
import AppKit
import SwiftUI

@main
struct MusicRoomApp: App {
    @NSApplicationDelegateAdaptor(MusicAppDelegate.self) private var appDelegate
    @StateObject private var model = LibraryModel()
    @StateObject private var updates = MacAppUpdates()
    @MusicAppearance private var theme
    @AppStorage(AppIconChoice.preferenceKey) private var iconStyle = AppIconChoice.defaultChoice.rawValue

    init() { MacAppUpdates.recordLaunchingProcess() }

    var body: some Scene {
        WindowGroup {
            MusicWindow(model: model)
                .environmentObject(updates)
                .frame(minWidth: 780, minHeight: 540)
                .preferredColorScheme(theme.scheme)
                .task {
                    appDelegate.library = model
                    updates.acknowledgeLaunch()
                    applyIcon()
                    model.restore()
                }
                .onChange(of: iconStyle) { _, _ in applyIcon() }
        }
        .defaultSize(width: 1120, height: 750)
        .commands {
            CommandMenu("Appearance") {
                Picker("App Icon", selection: $iconStyle) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
            }
        }
    }

    private func applyIcon() {
        let choice = AppIconChoice(rawValue: iconStyle) ?? .defaultChoice
        if iconStyle != choice.rawValue { iconStyle = choice.rawValue }
        if let icon = choice.macImage {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@MainActor
private final class MusicAppDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        library?.player.hasActivePlayback != true
    }
}

private struct MusicWindow: View {
    @ObservedObject var model: LibraryModel
    @State private var searchTask: Task<Void, Never>?
    @MusicAppearance private var theme
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @AppStorage(LibraryLayout.preferenceKey) private var libraryLayout = LibraryLayout.grid
    @AppStorage(LibraryArtworkSize.preferenceKey) private var libraryArtworkSize = LibraryArtworkSize.medium
    @AppStorage("LibrarySidebarWidth") private var sidebarPreference = 0
    @State private var videoSection: PlexVideoKind?
    @GestureState private var sidebarDrag: CGFloat = 0
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showSettings = false
    @State private var showNowPlaying = false
    @State private var showVolume = false
    @State private var miniPlayer = MacMiniPlayer()
    private var palette: ArtworkPalette? { artworkColors ? model.playingPalette : nil }
    private var copper: Color { theme.accent(using: palette) }

    var body: some View {
        ZStack {
            libraryContent
                .accessibilityHidden(showNowPlaying)
                .allowsHitTesting(!showNowPlaying)
                .disabled(showNowPlaying)
            if showNowPlaying {
                NowPlayingView(library: model) { showNowPlaying = false }
                    .modifier(NowPlayingPopTransition())
            }
        }
        .modifier(NowPlayingPresentation(showing: showNowPlaying))
        .background(theme.backdrop(using: palette))
        .toolbarBackground(theme.surface(using: palette), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(isPresented: $showSettings) { MusicSettings(library: model) }
        .sheet(item: $model.playlistEdit) { edit in PlexPlaylistEditor(library: model, edit: edit) }
        .foregroundStyle(theme.text)
        .tint(copper)
        .onChange(of: model.visibleVideoKinds) { _, enabled in
            if let videoSection, !enabled.contains(videoSection) { self.videoSection = nil }
        }
        .onChange(of: model.query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { model.browse() }
            }
        }
    }

    private var libraryContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resizableSidebar(availableWidth: geometry.size.width, defaultWidth: 216)
                    mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .musicGlass(theme, radius: 22)
                        .padding(7)
                }
                transport
            }
        }
    }

    private func resizableSidebar(availableWidth: CGFloat, defaultWidth: CGFloat) -> some View {
        let minimum: CGFloat = 164
        let maximum = max(minimum, min(420, availableWidth - 400))
        let preferred = sidebarPreference > 0 ? CGFloat(sidebarPreference) : defaultWidth
        let limit: (CGFloat) -> CGFloat = { min(maximum, max(minimum, $0)) }
        let startingWidth = limit(preferred)
        let width = limit(startingWidth + sidebarDrag)

        return HStack(spacing: 0) {
            sidebar(width: width).frame(width: width)
            Color.clear
                .frame(width: 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.set() }
                    else { NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($sidebarDrag) { value, translation, _ in translation = value.translation.width }
                    .onEnded { value in
                        sidebarPreference = Int(limit(startingWidth + value.translation.width).rounded())
                    })
                .onTapGesture(count: 2) { sidebarPreference = 0 }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) {
                    sidebarPreference = Int(limit(width - 16).rounded())
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    sidebarPreference = Int(limit(width + 16).rounded())
                    return .handled
                }
                .accessibilityLabel("Sidebar width")
                .accessibilityValue("\(Int(width.rounded())) points")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: sidebarPreference = Int(limit(width + 16).rounded())
                    case .decrement: sidebarPreference = Int(limit(width - 16).rounded())
                    @unknown default: break
                    }
                }
        }
    }

    private func sidebar(width: CGFloat) -> some View {
        let padding: CGFloat = 24
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderBrand(theme: theme, width: min(155, width - padding * 2), height: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        sidebarButton("Music", icon: "music.note", selected: videoSection == nil) { videoSection = nil }
                        ForEach(model.visibleVideoKinds) { videoTab($0) }
                    }
                    if videoSection == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.visibleKinds, id: \.self) { tab($0) }
                        }.padding(.leading, 8)
                    }
                }
                .padding(padding)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                settingsButton
            }
            .padding(.horizontal, padding)
            .padding(.top, 10)
            .padding(.bottom, padding)
        }
        .musicGlass(theme, radius: 20)
        .padding(7)
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sidebarButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).frame(width: 20)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .foregroundStyle(selected ? copper : theme.text)
            .background(selected ? copper.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func tab(_ kind: MusicKind) -> some View {
        sidebarButton(kind.rawValue, icon: kind.symbol, selected: model.kind == kind) {
            searchTask?.cancel()
            model.selectKind(kind)
        }.disabled(model.libraryID.isEmpty)
    }

    private func videoTab(_ kind: PlexVideoKind) -> some View {
        sidebarButton(kind.title, icon: kind.icon, selected: videoSection == kind) {
            videoSection = kind
        }.disabled(model.serverID.isEmpty)
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let videoSection, !model.serverID.isEmpty {
                PlexVideoBrowser(kind: videoSection, server: model.serverID, service: model.service,
                                 serverReady: model.videoServerReady, connectionError: model.busy ? nil : model.message,
                                 retryConnection: model.retryLibrary, pauseMusic: model.player.pause)
                    .id(model.serverID + videoSection.rawValue)
            } else if model.libraryID.isEmpty {
                if !model.libraries.isEmpty { musicBrowseHeader }
                welcome
            } else {
                musicBrowseHeader
                if let status = model.libraryConnectionStatus {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 28).padding(.bottom, 12)
                }
                if let message = model.message {
                    HStack {
                        Text(message).font(.callout).foregroundStyle(copper)
                        if !model.busy && model.selectedDetail == nil && !model.more {
                            Button("Retry", action: model.retryLibrary)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 12)
                }
                if let album = model.selectedDetail { albumDetail(album) }
                else { grid }
            }
        }
    }

    private var musicBrowseHeader: some View {
        LibraryBrowseHeader {
            HStack(spacing: 15) {
                if model.selectedDetail != nil || model.selectedGroup != nil {
                    Button {
                        if model.selectedDetail != nil { model.closeDetail() }
                        else { model.browse() }
                    } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
                }
                Text(model.libraryID.isEmpty ? "Music" :
                     model.selectedDetail?.title ?? model.selectedGroup?.title ?? model.kind.rawValue)
                    .font(.system(size: 31, weight: .bold)).lineLimit(1)
                if model.kind == .playlists && model.selectedDetail == nil && model.selectedGroup == nil {
                    Button("New Playlist", systemImage: "plus") { model.editPlaylist() }
                        .disabled(!model.canEditPlaylists)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } controls: {
            LibraryBrowseControls(placeholder: "Search " + model.kind.rawValue.lowercased(),
                                  query: model.selectedDetail == nil && model.selectedGroup == nil ? $model.query : nil,
                                  searchDisabled: model.reconnecting || model.libraryID.isEmpty) {
                PlexLibrarySwitcher(library: model)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "record.circle")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(copper)
                .accessibilityHidden(true)
            Text(model.connected ? "Choose your music library" : "Your music. Your server.")
                .font(.system(size: 38, weight: .bold))
            Text(!model.libraries.isEmpty ? "Select a music library above." :
                 model.connected ? "Choose a Plex server and music library in Settings." :
                 "Connect to Plex to browse your collection and play your music.")
                .foregroundStyle(.secondary)
            connectionControls
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var connectionControls: some View {
        if let message = model.message { Text(message).foregroundStyle(copper) }
        if model.busy {
            ProgressView(model.signInURL == nil ? "Connecting…" : "Waiting for Plex sign-in…")
            HStack {
                if let url = model.signInURL { Link("Reopen Plex sign-in", destination: url) }
                Button("Cancel") { model.cancel() }
            }
        } else if !model.connected {
            Button("Connect Plex", action: model.signIn).buttonStyle(.borderedProminent)
        } else {
            Button("Open Plex Settings") { showSettings = true }.buttonStyle(.borderedProminent)
        }
    }

    private var grid: some View {
        ScrollView {
            if model.selectedGroup == nil && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PinnedMusicShelf(library: model) { searchTask?.cancel(); model.open($0) }
                    .padding(.horizontal, 28).padding(.bottom, model.pins.isEmpty ? 0 : 14)
            }
            if !model.busy && model.entries.isEmpty {
                Text("No matches in this library.").foregroundStyle(.secondary).padding(26)
            }
            if model.kind == .genres && model.selectedGroup == nil {
                MusicGenreList(library: model) { searchTask?.cancel(); model.open($0) }
                    .padding(.horizontal, 28).padding(.bottom, 24)
            } else if libraryLayout.applies(to: model.kind, inGroup: model.selectedGroup != nil) {
                LibraryAlternateLayout(library: model, layout: libraryLayout)
                    .padding(.horizontal, 28).padding(.bottom, 24)
            } else {
                let trackList = model.kind == .tracks && model.selectedGroup == nil
                let scale = libraryArtworkSize.scale
                let artwork = GridItem.Size.adaptive(minimum: (145 * scale).rounded(),
                                                     maximum: (190 * scale).rounded())
                LazyVGrid(columns: [GridItem(trackList ? .flexible() : artwork, spacing: 21)],
                          alignment: .leading, spacing: trackList ? 8 : 24) {
                    ForEach(model.entries) { entry in
                        Button { searchTask?.cancel(); model.open(entry) } label: {
                            let layout = trackList ? AnyLayout(HStackLayout(spacing: 12)) :
                                AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
                            layout {
                                CoverArt(item: entry, model: model)
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(width: trackList ? 46 : nil, height: trackList ? 46 : nil)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.headline).lineLimit(1)
                                    if !entry.artist.isEmpty {
                                        Text(entry.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !entry.kind.isGroup { LibraryQueueActions(library: model, entry: entry) }
                            PlexPinButton(library: model, entry: entry)
                        }
                    }
                    if model.more && !model.busy && model.message == nil {
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                            .id(model.entries.count)
                            .onAppear { model.loadMore() }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
            if model.busy { ProgressView().controlSize(.small).padding() }
            if model.more && !model.busy && model.message != nil {
                Button("Retry", action: model.loadMore).padding(.bottom, 24)
            }
        }
    }

    private func albumDetail(_ album: MusicEntry) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 22) {
                    CoverArt(item: album, model: model).frame(width: 156, height: 156)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(album.artist.isEmpty ? album.kind.plexName.capitalized : album.artist).font(.title3.weight(.semibold))
                        let info = [album.year.map(String.init), album.genres.first].compactMap { $0 }
                        if !info.isEmpty { Text(info.joined(separator: " · ")).foregroundStyle(.secondary) }
                        Button { model.play(at: 0) } label: { Label(album.kind.playLabel, systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(model.tracks.isEmpty)
                        PlexPinButton(library: model, entry: album)
                        Menu("Queue", systemImage: "list.bullet") { LibraryQueueActions(library: model, entry: album) }
                            .disabled(model.tracks.isEmpty)
                    }
                }
                if model.busy { ProgressView("Loading tracks…") }
                if let message = model.message, model.tracks.isEmpty {
                    Button("Retry") { model.open(album) }.help(message)
                }
                if album.kind == .playlists {
                    if model.savingPlaylistTrack { ProgressView("Saving playlist…") }
                    if let message = model.playlistTrackMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if model.tracks.isEmpty && !model.busy && !model.savingPlaylistTrack && model.message == nil {
                        Text("This playlist is empty.").foregroundStyle(.secondary)
                    }
                }
                let popular = model.popularTrackIDs
                ForEach(Array(model.tracks.enumerated()), id: \.offset) { index, track in
                    Button { model.play(at: index) } label: {
                        HStack(spacing: 14) {
                            if let current = model.state.index, model.playingTracks.indices.contains(current),
                               model.playingTracks[current].id == track.id {
                                Image(systemName: "waveform").foregroundStyle(copper).frame(width: 30)
                            } else {
                                Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                            }
                            Text(track.title).lineLimit(1)
                            if popular.contains(track.id) { PopularTrackBadge() }
                            Spacer()
                            if let duration = track.duration { Text(clock(duration)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .contextMenu { LibraryQueueActions(library: model, entry: album, track: track) }
                        .modifier(PlaylistTrackEditing(library: model, track: track))
                    Divider()
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            transportMetadata
            Spacer()
            miniPlayerButton
            transportButtons
            seekControl.frame(width: 130)
            Text(clock(model.state.elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
            Button { showVolume.toggle() } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.borderless).accessibilityLabel("Volume")
                .popover(isPresented: $showVolume) {
                    Slider(value: Binding(get: { model.playbackVolume }, set: model.changePlaybackVolume), in: 0...1) {
                        Text("Playback volume")
                    }
                    .frame(width: 185).padding(16)
                }
        }
        .padding(.horizontal, 22).frame(height: 69)
        .musicGlass(theme, radius: 24)
        .padding(8)
    }

    @ViewBuilder private var miniPlayerButton: some View {
        if model.playingAlbum != nil {
            Button("Mini-player", systemImage: "macwindow.on.rectangle") {
                if let window = NSApp.keyWindow {
                    miniPlayer.show(library: model, style: miniPlayerStyle.resolved, hiding: window)
                }
            }
        }
    }

    @ViewBuilder private var transportMetadata: some View {
        if let album = model.playingAlbum {
            Button { showNowPlaying = true } label: {
                HStack(spacing: 11) {
                    if let image = model.playingArtwork {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 46, height: 46).clipShape(.rect(cornerRadius: 8))
                    } else {
                        CoverArt(item: album, model: model).frame(width: 46, height: 46)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.state.title.isEmpty ? album.title : model.state.title).font(.headline).lineLimit(1)
                        Text([model.currentTrack?.artist ?? album.artist, model.currentTrack?.album ?? album.title]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !model.state.message.isEmpty {
                            Text(model.state.message).font(.caption2).foregroundStyle(copper).lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Now Playing")
            .help("Open Now Playing")
        } else {
            Text("Nothing playing").foregroundStyle(.secondary)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 16) {
            Button { model.player.previous() } label: { Image(systemName: "backward.fill") }
                .disabled(!model.state.previous).accessibilityLabel("Previous")
            Button { model.player.toggle() } label: {
                Image(systemName: model.state.playing ? "pause.fill" : "play.fill").font(.title3)
                    .foregroundStyle(theme.text)
            }
            .disabled(model.playingAlbum == nil).accessibilityLabel(model.state.playing ? "Pause" : "Play")
            Button { model.player.next() } label: { Image(systemName: "forward.fill") }
                .disabled(!model.state.next).accessibilityLabel("Next")
        }.buttonStyle(.borderless)
    }

    private var seekControl: some View {
        Slider(value: Binding(get: { min(model.state.elapsed, model.state.duration) }, set: model.player.seek),
               in: 0...max(1, model.state.duration))
            .disabled(model.state.duration <= 0).accessibilityLabel("Playback position")
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(max(0, min(seconds, 999_999)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct CoverArt: View {
    let item: MusicEntry
    @ObservedObject var model: LibraryModel

    var body: some View {
        Color.white.opacity(0.055)
            .overlay {
                PlexArtwork(item: item, library: model) {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

#endif
