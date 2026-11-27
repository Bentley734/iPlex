#if os(iOS) || os(tvOS)
import SwiftUI
import ToolDriveMobile

@main
struct MobileMusicRoomApp: App {
    @MusicAppearance private var theme
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            MusicLibraryScreen(library: library)
                .preferredColorScheme(theme.scheme)
                .tint(theme.accent)
                .task {
                    library.restore()
                    await MusicAppIconPicker.resetUnavailableIcon()
                }
        }
    }
}

private struct MusicLibraryScreen: View {
    @ObservedObject var library: LibraryModel
    @MusicAppearance private var theme
    @AppStorage(LiquidGlassAppearance.transparencyKey) private var glassTransparency = LiquidGlassAppearance.defaultTransparency
    @AppStorage(LiquidGlassTint.preferenceKey) private var glassTint = LiquidGlassTint.themeDefault
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @State private var showSettings = false
    @AppStorage(LibraryLayout.preferenceKey) private var libraryLayout = LibraryLayout.grid
    @AppStorage(LibraryArtworkSize.preferenceKey) private var libraryArtworkSize = LibraryArtworkSize.medium
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showAppIcons = false
    @State private var showPlayer = false
    @StateObject private var archiveTransport = ToolDriveTransport()
    @State private var showMiniPlayer = false
    @State private var search: Task<Void, Never>?

    private var palette: ArtworkPalette? { artworkColors ? library.playingPalette : nil }
    private var accent: Color { theme.accent(using: palette) }
    private var videoSection: PlexVideoKind? { library.videoSection }

    private var columnWidth: CGFloat {
        #if os(tvOS)
        225
        #else
        135
        #endif
    }

    private var artworkColumns: GridItem.Size {
        let width = (columnWidth * libraryArtworkSize.scale).rounded()
        return .adaptive(minimum: width, maximum: libraryArtworkSize == .medium ? .infinity : (width * 1.25).rounded())
    }

    var body: some View {
        ZStack {
            libraryScreen
                .accessibilityHidden(showPlayer || showMiniPlayer)
                .allowsHitTesting(!showPlayer && !showMiniPlayer)
                #if os(tvOS)
                .disabled(showPlayer || showMiniPlayer)
                #endif
            if showPlayer {
                NowPlayingView(library: library, archive: library.toolDriveSelected ? archiveTransport : nil) { showPlayer = false }
                    .modifier(NowPlayingPopTransition())
            }
            if showMiniPlayer {
                Color.black.ignoresSafeArea()
                MiniPlayerContent(library: library, style: miniPlayerStyle.resolved) { showMiniPlayer = false }
            }
        }
        .modifier(NowPlayingPresentation(showing: showPlayer))
        .task { await archiveTransport.prepareCatalog() }
        .foregroundStyle(theme.text)
        .tint(accent)
        #if os(iOS)
        .statusBarHidden(showMiniPlayer)
        #endif
        .sheet(isPresented: $showSettings) { MusicSettings(library: library) }
        .sheet(item: $library.playlistEdit) { edit in PlexPlaylistEditor(library: library, edit: edit) }
        .sheet(isPresented: $showAppIcons) { MusicAppIconPicker() }
        .onChange(of: library.query) { _, _ in
            search?.cancel()
            search = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { library.browse() }
            }
        }
    }

    private var browseRoute: [String] {
        if library.toolDriveSelected || library.downloadsSelected { return [library.activeSection.rawValue] }
        if let videoSection { return [videoSection.rawValue] }
        return ["music", library.libraryID, library.kind.rawValue, library.selectedGroup?.id ?? "", library.selectedDetail?.id ?? ""]
    }

    private var libraryScreen: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeaderBrand(section: library.activeSection,
                                   theme: theme, width: columnWidth, height: 56)
                Spacer()
                Button { showAppIcons = true } label: { Image(systemName: "app.dashed") }
                    .accessibilityLabel("App Icon")
                    .glassHover()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .glassHover()

            }
            .padding(.horizontal, 20)
            .musicGlass(theme, radius: 20)
            .padding(.horizontal, 12)
            #if os(tvOS)
            .focusSection()
            #endif
            #if os(iOS)
            ScrollView(.horizontal) { sectionTabs }.scrollIndicators(.hidden)
            #else
            sectionTabs.focusSection()
            #endif
            if library.musicNavigationSelected && (library.toolDriveSelected ||
                (library.selectedDetail == nil && library.selectedGroup == nil)) {
                #if os(tvOS)
                sectionButtons.focusSection()
                #else
                ScrollView(.horizontal) { sectionButtons }.scrollIndicators(.hidden)
                #endif
            }
            VStack(spacing: 0) {
                if library.toolDriveSelected {
                    ToolDriveArchiveView(title: library.sectionName(.toolDrive), text: theme.text,
                                         accent: accent, tint: glassTint.color(for: theme),
                                         density: LiquidGlassAppearance.density(glassTransparency),
                                         transport: archiveTransport, pauseOutsidePlayback: library.player.pause,
                                         plexSettings: { AnyView(MusicSettings(library: library)) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .musicGlass(theme, radius: 22)
                        .clipShape(.rect(cornerRadius: 22))
                        .padding(.horizontal, 12)
                } else if library.downloadsSelected {
                    DownloadsBrowser(library: library)
                } else if let videoSection, !library.serverID.isEmpty {
                    PlexVideoBrowser(kind: videoSection, server: library.serverID, service: library.service,
                                     serverReady: library.videoServerReady, connectionError: library.busy ? nil : library.message,
                                     retryConnection: library.retryLibrary, pauseMusic: library.player.pause,
                                     sectionName: library.sectionName(HeaderBrandSection(video: videoSection)))
                        .id(library.serverID + videoSection.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .musicGlass(theme, radius: 22)
                        .padding(.horizontal, 12)
                } else if library.libraryID.isEmpty {
                    VStack {
                        if !library.libraries.isEmpty { musicBrowseControls.padding(14) }
                        connection.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                        .musicGlass(theme, radius: 22)
                        .padding(.horizontal, 12)
                } else {
                    browser
                        .musicGlass(theme, radius: 22)
                        .padding(.horizontal, 12)
                }
                if library.toolDriveSelected, let title = archiveTransport.title {
                    playbackBar(title: title, detail: archiveTransport.context, isArchive: true,
                                open: {
                                    archiveTransport.setPlaybackVolume(library.playbackVolume)
                                    showPlayer = true
                                }) {
                        Image(systemName: "waveform").foregroundStyle(accent)
                    }
                } else if !library.toolDriveSelected, let album = library.playingAlbum {
                    playbackBar(title: library.state.title.isEmpty ? album.title : library.state.title,
                                detail: [library.currentTrack?.artist ?? album.artist, library.currentTrack?.album ?? album.title]
                                    .filter { !$0.isEmpty }.joined(separator: " · "),
                                isArchive: false, open: { showPlayer = true }) {
                        if let image = library.playingArtwork {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            MusicArtwork(item: album, library: library)
                        }
                    }
                }
            }
            .pageTransition(on: browseRoute)
            .clipped()
        }
        .background(theme.backdrop(using: palette).ignoresSafeArea())
    }

    private func playbackBar<Artwork: View>(title: String, detail: String, isArchive: Bool,
                                            open: @escaping () -> Void,
                                            @ViewBuilder artwork: () -> Artwork) -> some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 14) {
                    artwork()
                        .frame(width: 43, height: 43)
                        .clipShape(.rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }.lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up").accessibilityHidden(true)
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            .accessibilityLabel("Open Now Playing")
            .buttonStyle(.bordered)
            .musicGlass(theme, radius: 20, interactive: true)
            if !isArchive {
                Button("Mini-player", systemImage: "ipod") { showMiniPlayer = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
    }

    private var sectionTabs: some View {
        HStack {
            ForEach(library.serverID.isEmpty ? [] : library.visibleVideoKinds) { kind in
                sectionTab(HeaderBrandSection(video: kind), icon: kind.icon) { library.selectVideoSection(kind) }
            }
            sectionTab(.music, icon: "music.note") { library.selectVideoSection(nil) }
            sectionTab(.downloads, icon: "arrow.down.circle", action: library.selectDownloads)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func sectionTab(_ section: HeaderBrandSection, icon: String, action: @escaping () -> Void) -> some View {
        let selected = section == .music ? library.musicNavigationSelected : library.activeSection == section
        return Button(library.sectionName(section), systemImage: icon, action: action)
            .lineLimit(1)
            .tint(selected ? accent : .primary)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .glassHover()
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(library.connected ? "Plex music library" : "Connect to Plex").font(.largeTitle.bold())
            if let message = library.message { Text(message).foregroundStyle(.secondary) }
            if library.busy {
                if let code = library.linkCode {
                    Text("On your phone or computer, go to plex.tv/link and enter this code.")
                    Text(code).font(.system(size: 60, weight: .bold, design: .monospaced))
                        .accessibilityLabel("Link code " + code.map(String.init).joined(separator: " "))
                } else {
                    ProgressView(library.signInURL == nil ? "Connecting…" : "Waiting for Plex sign-in…")
                    #if os(iOS)
                    if let url = library.signInURL { Link("Reopen Plex sign-in", destination: url) }
                    #endif
                }
                Button("Cancel", action: library.cancel)
            } else if library.connected {
                Text(library.libraries.isEmpty ? "Choose a Plex server and music library in Settings." :
                     "Select a music library above.").foregroundStyle(.secondary)
                Button("Open Plex Settings") { showSettings = true }.buttonStyle(.borderedProminent)
            } else {
                Button("Connect Plex", action: library.signIn).buttonStyle(.borderedProminent)
            }
        }.padding(24)
    }

    private var musicBrowseControls: some View {
        LibraryBrowseControls(placeholder: "Search " + library.kind.rawValue.lowercased(),
                              query: library.selectedDetail == nil && library.selectedGroup == nil ? $library.query : nil,
                              searchDisabled: library.reconnecting || library.libraryID.isEmpty) {
            PlexLibrarySwitcher(library: library)
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.selectedDetail == nil && library.selectedGroup == nil {
                if library.kind == .playlists {
                    Button("New Playlist", systemImage: "plus") { library.editPlaylist() }
                        .disabled(!library.canEditPlaylists)
                }
            } else {
                Button {
                    if library.selectedDetail != nil { library.closeDetail() }
                    else { library.browse() }
                } label: { Label("Back", systemImage: "chevron.left") }
            }
            musicBrowseControls
            if let status = library.libraryConnectionStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let message = library.message {
                HStack {
                    Text(message).foregroundStyle(.secondary)
                    if !library.busy && library.selectedDetail == nil && !library.more {
                        Button("Retry", action: library.retryLibrary)
                    }
                }
            }
            ScrollView {
                if let album = library.selectedDetail { albumDetails(album) }
                else {
                    if library.selectedGroup == nil && library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        PinnedMusicShelf(library: library) { search?.cancel(); library.open($0) }
                    }
                    if let artist = library.selectedGroup {
                        Text(artist.title).font(.largeTitle.bold()).padding(.bottom, 16)
                    }
                    if !library.busy && library.entries.isEmpty { Text("No matches in this library.").foregroundStyle(.secondary) }
                    if library.kind == .genres && library.selectedGroup == nil {
                        MusicGenreList(library: library) { search?.cancel(); library.open($0) }
                    } else if libraryLayout.applies(to: library.kind, inGroup: library.selectedGroup != nil) {
                        LibraryAlternateLayout(library: library, layout: libraryLayout)
                    } else {
                        let trackList = library.kind == .tracks && library.selectedGroup == nil
                        LazyVGrid(columns: [GridItem(trackList ? .flexible() : artworkColumns, spacing: 20, alignment: .top)],
                                  spacing: trackList ? 8 : 20) {
                            ForEach(library.entries) { entry in
                                Button { search?.cancel(); library.open(entry) } label: {
                                    let layout = trackList ? AnyLayout(HStackLayout(spacing: 12)) :
                                        AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
                                    layout {
                                        MusicArtwork(item: entry, library: library)
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(width: trackList ? 46 : nil, height: trackList ? 46 : nil)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title).font(.headline).lineLimit(trackList ? 1 : 2)
                                                .multilineTextAlignment(.leading)
                                            if !entry.artist.isEmpty {
                                                Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                #if os(tvOS)
                                .buttonStyle(.card)
                                #else
                                .buttonStyle(.plain)
                                #endif
                                .glassHover(lift: !trackList)
                                .contextMenu {
                                    if !entry.kind.isGroup { LibraryQueueActions(library: library, entry: entry) }
                                    PlexPinButton(library: library, entry: entry)
                                }
                            }
                            if library.more && !library.busy && library.message == nil {
                                Color.clear.frame(height: 1).accessibilityHidden(true)
                                    .id(library.entries.count)
                                    .onAppear { library.loadMore() }
                            }
                        }
                    }

                }
                if library.busy { ProgressView().padding() }
                if library.more && !library.busy && library.selectedDetail == nil && library.message != nil {
                    Button("Retry", action: library.loadMore).padding()
                }
            }
            .libraryScrollTopInset()
            .contentMargins(.horizontal, 8, for: .scrollContent)
        }.padding(14)
    }

    private var sectionButtons: some View {
        HStack {
            ForEach(library.visibleKinds, id: \.self) { kind in
                let selected = !library.toolDriveSelected && library.kind == kind
                Button(kind.rawValue) {
                    search?.cancel()
                    library.selectKind(kind)
                }
                .disabled(library.libraryID.isEmpty)
                .tint(selected ? accent : Color.gray)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            sectionTab(.toolDrive, icon: "waveform", action: library.selectToolDrive)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 26).padding(.bottom, 8)
    }

    private func albumDetails(_ album: MusicEntry) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                MusicArtwork(item: album, library: library).frame(width: columnWidth, height: columnWidth)
                VStack(alignment: .leading, spacing: 8) {
                    Text(album.title).font(.title.bold())
                    Text(album.artist)
                    let description = [album.year.map(String.init), album.genres.first].compactMap { $0 }.joined(separator: " · ")
                    if !description.isEmpty { Text(description).foregroundStyle(.secondary) }
                    Button(album.kind.playLabel) { library.play(at: 0) }
                        .buttonStyle(.borderedProminent).disabled(library.tracks.isEmpty)
                    PlexPinButton(library: library, entry: album)
                    Menu("Queue", systemImage: "list.bullet") { LibraryQueueActions(library: library, entry: album) }
                        .disabled(library.tracks.isEmpty)
                }
                Spacer(minLength: 0)
            }
            if album.kind == .playlists {
                if library.savingPlaylistTrack { ProgressView("Saving playlist…") }
                if let message = library.playlistTrackMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                if library.tracks.isEmpty && !library.busy && !library.savingPlaylistTrack && library.message == nil {
                    Text("This playlist is empty.").foregroundStyle(.secondary)
                }
            }
            let popular = library.popularTrackIDs
            ForEach(Array(library.tracks.enumerated()), id: \.offset) { index, track in
                Button { library.play(at: index) } label: {
                    HStack {
                        Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary)
                        Text(track.title).lineLimit(1)
                        if popular.contains(track.id) { PopularTrackBadge() }
                        Spacer()
                        if let duration = track.duration { Text(clock(duration)).monospacedDigit() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered)
                    .contextMenu { LibraryQueueActions(library: library, entry: album, track: track) }
                    .modifier(PlaylistTrackEditing(library: library, track: track))
            }
        }.frame(maxWidth: 1000, alignment: .leading)
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, min(999_999, seconds)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct MusicArtwork: View {
    let item: MusicEntry
    @ObservedObject var library: LibraryModel

    var body: some View {
        Color.white.opacity(0.08).overlay {
            PlexArtwork(item: item, library: library) {
                Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
#endif
