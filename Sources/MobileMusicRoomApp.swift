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
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showAppIcons = false
    @State private var showPlayer = false
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

    var body: some View {
        ZStack {
            if showPlayer, let style = selectedMiniPlayer {
                Color.black.ignoresSafeArea()
                MiniPlayerContent(library: library, style: style) { showPlayer = false }
            } else {
                libraryScreen
            }
        }
        .tint(accent)
        #if os(iOS)
        .statusBarHidden(showPlayer && selectedMiniPlayer != nil)
        #endif
        .sheet(isPresented: $showSettings) { MusicSettings(library: library) }
        .sheet(isPresented: $showAppIcons) { MusicAppIconPicker() }
        .sheet(isPresented: Binding(get: { showPlayer && selectedMiniPlayer == nil },
                                    set: { showPlayer = $0 })) {
            nowPlaying.padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.backdrop(using: palette).ignoresSafeArea())
        }
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
                    Button { showPlayer = true } label: {
                        HStack(spacing: 14) {
                            MusicArtwork(item: album, library: library).frame(width: 43, height: 43)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(library.state.title.isEmpty ? album.title : library.state.title).font(.headline)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary)
                            }.lineLimit(1)
                            Spacer()
                            Image(systemName: "waveform")
                        }.padding(.horizontal, 14).padding(.vertical, 8)
                    }.accessibilityLabel("Open Now Playing")
                        .buttonStyle(.bordered)
                        .musicGlass(theme, radius: 20, interactive: true)
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
                TextField("Search " + library.kind.rawValue.lowercased(), text: $library.query)
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
            if let message = library.message { Text(message).foregroundStyle(.secondary) }
            ScrollView {
                if let album = library.selectedDetail { albumDetails(album) }
                else {
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
                    LazyVGrid(columns: [GridItem(trackList ? .flexible() : .adaptive(minimum: columnWidth), spacing: 20)],
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
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(library.tracks.enumerated()), id: \.offset) { index, track in
                Button { library.play(at: index) } label: {
                    HStack {
                        Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary)
                        Text(track.title).lineLimit(1)
                        Spacer()
                        if let duration = track.duration { Text(clock(duration)).monospacedDigit() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: 1000, alignment: .leading)
    }

    private var nowPlaying: some View {
        VStack(spacing: 18) {
            if let album = library.playingAlbum {
                let artworkSize = theme == .plexify ? columnWidth * 1.3 : columnWidth
                MusicArtwork(item: album, library: library).frame(width: artworkSize, height: artworkSize)
                Text(library.state.title).font(.title.bold())
                Text([album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                if !library.state.message.isEmpty { Text(library.state.message) }
                Text(clock(library.state.elapsed) + " / " + clock(library.state.duration)).monospacedDigit()
                #if os(iOS)
                Slider(value: Binding(get: { min(library.state.elapsed, library.state.duration) },
                                      set: { library.player.seek(to: $0) }), in: 0...max(1, library.state.duration))
                    .disabled(library.state.duration <= 0).accessibilityLabel("Playback position")
                #endif
                HStack {
                    Button("Previous", systemImage: "backward.fill", action: library.player.previous)
                        .labelStyle(.iconOnly).disabled(!library.state.previous)
                    Button(library.state.playing ? "Pause" : "Play",
                           systemImage: library.state.playing ? "pause.fill" : "play.fill", action: library.player.toggle).labelStyle(.iconOnly)
                    Button("Next", systemImage: "forward.fill", action: library.player.next)
                        .labelStyle(.iconOnly).disabled(!library.state.next)
                }.buttonStyle(.bordered)
                if theme == .plexify, let next = library.state.nextTitle {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(next).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(theme.surface(using: palette), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Button("Done") { showPlayer = false }
        }.frame(maxWidth: 500)
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
