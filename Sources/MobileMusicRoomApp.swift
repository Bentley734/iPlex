#if os(iOS) || os(tvOS)
import SwiftUI

@main
struct MobileMusicRoomApp: App {
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
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
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @State private var showSettings = false
    @AppStorage(LibraryArtworkSize.preferenceKey) private var libraryArtworkSize = LibraryArtworkSize.medium
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showAppIcons = false
    @State private var showPlayer = false
    @State private var showMiniPlayer = false
    @State private var search: Task<Void, Never>?

    private var palette: ArtworkPalette? { artworkColors ? library.playingPalette : nil }
    private var accent: Color { theme.accent(using: palette) }
    private var selectedMiniPlayer: MiniPlayerStyle? { miniPlayerStyle.resolve(for: theme) }

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
                NowPlayingView(library: library) { showPlayer = false }
                    .modifier(NowPlayingPopTransition())
            }
            if showMiniPlayer, let style = selectedMiniPlayer {
                Color.black.ignoresSafeArea()
                MiniPlayerContent(library: library, style: style) { showMiniPlayer = false }
            }
        }
        .modifier(NowPlayingPresentation(showing: showPlayer))
        .tint(accent)
        #if os(iOS)
        .statusBarHidden(showMiniPlayer)
        #endif
        .sheet(isPresented: $showSettings) { MusicSettings(library: library) }
        .sheet(isPresented: $showAppIcons) { MusicAppIconPicker() }
        .onChange(of: library.query) { _, _ in
            search?.cancel()
            search = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { library.browse() }
            }
        }
    }

    private var libraryScreen: some View {
        VStack(spacing: 0) {
            HStack {
                HeaderBrand(mark: headerMark, theme: theme, width: columnWidth, height: 56)
                Spacer()
                Button { showAppIcons = true } label: { Image(systemName: "app.dashed") }
                    .accessibilityLabel("App Icon")
                PlexLibrarySwitcher(library: library)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")

            }
            .padding(.horizontal, 20)
            .musicGlass(theme, radius: 20)
            .padding(.horizontal, theme == .liquidGlass ? 12 : 0)
            #if os(tvOS)
            .focusSection()
            #endif
            if library.libraryID.isEmpty {
                connection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browser
                if let album = library.playingAlbum {
                    HStack(spacing: 8) {
                        Button { showPlayer = true } label: {
                            HStack(spacing: 14) {
                                Group {
                                    if let image = library.playingArtwork {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        MusicArtwork(item: album, library: library)
                                    }
                                }
                                .frame(width: 43, height: 43)
                                .clipShape(.rect(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(library.state.title.isEmpty ? album.title : library.state.title).font(.headline)
                                    Text([library.currentTrack?.artist ?? album.artist, library.currentTrack?.album ?? album.title]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up").accessibilityHidden(true)
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        .accessibilityLabel("Open Now Playing")
                        .buttonStyle(.bordered)
                        .musicGlass(theme, radius: 20, interactive: true)
                        if selectedMiniPlayer != nil {
                            Button("Mini-player", systemImage: "ipod") { showMiniPlayer = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(theme.backdrop(using: palette).ignoresSafeArea())
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
                Text("Choose a Plex server and music library in Settings.").foregroundStyle(.secondary)
                Button("Open Plex Settings") { showSettings = true }.buttonStyle(.borderedProminent)
            } else {
                Button("Connect Plex", action: library.signIn).buttonStyle(.borderedProminent)
            }
        }.padding(24)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.selectedDetail == nil && library.selectedGroup == nil {
                #if os(tvOS)
                HStack { sectionButtons }
                #else
                ScrollView(.horizontal) {
                    HStack { sectionButtons }
                }.scrollIndicators(.hidden)
                #endif
                TextField("Search " + library.kind.rawValue.lowercased(), text: $library.query).disabled(library.reconnecting)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .padding(10)
                    .background(theme == .liquidGlass ? .clear : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9))
                    .musicGlass(theme, radius: 13)
            } else {
                Button {
                    if library.selectedDetail != nil { library.closeDetail() }
                    else { library.browse() }
                } label: { Label("Back", systemImage: "chevron.left") }
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
                    if theme == .plexify && library.selectedGroup == nil && [.albums, .artists].contains(library.kind)
                        && library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let entry = library.entries.first {
                        PlexifyFeature(item: entry, library: library) { library.open(entry) }
                            .padding(.bottom, 13)
                    }
                    if let artist = library.selectedGroup {
                        Text(artist.title).font(.largeTitle.bold()).padding(.bottom, 16)
                    }
                    if !library.busy && library.entries.isEmpty { Text("No matches in this library.").foregroundStyle(.secondary) }
                    let trackList = library.kind == .tracks && library.selectedGroup == nil
                    LazyVGrid(columns: [GridItem(trackList ? .flexible() : artworkColumns, spacing: 20)],
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
                                        Text(entry.title).font(.headline).lineLimit(1)
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
                if library.busy { ProgressView().padding() }
                if library.more && !library.busy && library.selectedDetail == nil && library.message != nil {
                    Button("Retry", action: library.loadMore).padding()
                }
            }.contentMargins(.horizontal, 8, for: .scrollContent)
        }.padding(14)
    }

    private var sectionButtons: some View {
        ForEach(library.visibleKinds, id: \.self) { kind in
            Button(kind.rawValue) {
                search?.cancel()
                library.selectKind(kind)
            }
            .buttonStyle(.bordered)
            .tint(library.kind == kind ? accent : Color.gray)
            .accessibilityAddTraits(library.kind == kind ? .isSelected : [])
        }
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
