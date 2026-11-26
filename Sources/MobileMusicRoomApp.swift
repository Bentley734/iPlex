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
                .task { library.restore() }
        }
    }
}

private struct MusicLibraryScreen: View {
    @ObservedObject var library: LibraryModel
    @State private var showConnection = false
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @State private var showSettings = false
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showAppIcons = false
    @State private var showPlayer = false
    @State private var search: Task<Void, Never>?

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
        #if os(iOS)
        .statusBarHidden(showPlayer && selectedMiniPlayer != nil)
        #endif
        .sheet(isPresented: $showSettings) { MusicSettings(library: library) }
        .sheet(isPresented: $showConnection) { connection.padding(26) }
        .sheet(isPresented: $showAppIcons) { MusicAppIconPicker() }
        .sheet(isPresented: Binding(get: { showPlayer && selectedMiniPlayer == nil },
                                    set: { showPlayer = $0 })) { nowPlaying.padding(24) }
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
                if library.connected {
                    Button { showConnection = true } label: { Image(systemName: "server.rack") }
                        .accessibilityLabel("Plex settings")
                }
            }
            .padding(.horizontal, 20)
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
                        .buttonStyle(.bordered).padding(.horizontal, 16)
                }
            }
        }
        .background(theme.backdrop.ignoresSafeArea())
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
                if library.servers.isEmpty {
                    Button("Refresh Servers", action: library.restore)
                } else {
                    Picker("Server", selection: Binding(get: { library.serverID }, set: library.chooseServer)) {
                        Text("Choose server").tag("")
                        ForEach(library.servers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                if !library.libraries.isEmpty {
                    Picker("Music library", selection: Binding(get: { library.libraryID }, set: library.chooseLibrary)) {
                        Text("Choose library").tag("")
                        ForEach(library.libraries, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Button("Disconnect Plex", action: library.disconnect)
                if showConnection { Button("Done") { showConnection = false } }
            } else {
                Button("Connect Plex", action: library.signIn).buttonStyle(.borderedProminent)
            }
        }.padding(24)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            if library.selectedAlbum == nil && library.selectedArtist == nil {
                HStack {
                    ForEach(MusicKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue) {
                            search?.cancel()
                            library.kind = kind
                            library.browse()
                        }
                        .buttonStyle(.bordered)
                        .tint(library.kind == kind ? theme.accent : Color.gray)
                        .accessibilityAddTraits(library.kind == kind ? .isSelected : [])
                    }
                    TextField("Search " + library.kind.rawValue.lowercased(), text: $library.query)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .padding(10).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
            } else {
                Button {
                    if library.selectedAlbum != nil { library.closeAlbum() }
                    else { library.browse() }
                } label: { Label("Back", systemImage: "chevron.left") }
            }
            if let message = library.message { Text(message).foregroundStyle(.secondary) }
            ScrollView {
                if let album = library.selectedAlbum { albumDetails(album) }
                else {
                    if theme == .plexify && library.selectedArtist == nil
                        && library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let entry = library.entries.first {
                        PlexifyFeature(item: entry, library: library) { library.open(entry) }
                            .padding(.bottom, 13)
                    }
                    if let artist = library.selectedArtist {
                        Text(artist.title).font(.largeTitle.bold()).padding(.bottom, 16)
                    }
                    if !library.busy && library.entries.isEmpty { Text("No matches in this library.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 20)], spacing: 20) {
                        ForEach(library.entries) { entry in
                            Button { search?.cancel(); library.open(entry) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    MusicArtwork(item: entry, library: library).aspectRatio(1, contentMode: .fit)
                                    Text(entry.title).font(.headline).lineLimit(1)
                                    if !entry.artist.isEmpty { Text(entry.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
                if library.more && !library.busy && library.selectedAlbum == nil && library.message != nil {
                    Button("Retry", action: library.loadMore).padding()
                }
            }.contentMargins(.horizontal, 8, for: .scrollContent)
        }.padding(14)
    }

    private func albumDetails(_ album: MusicEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                MusicArtwork(item: album, library: library).frame(width: columnWidth, height: columnWidth)
                VStack(alignment: .leading, spacing: 8) {
                    Text(album.title).font(.title.bold())
                    Text(album.artist)
                    let description = [album.year.map(String.init), album.genres.first].compactMap { $0 }.joined(separator: " · ")
                    if !description.isEmpty { Text(description).foregroundStyle(.secondary) }
                    Button("Play Album") { library.play(at: 0) }
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
                        Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                        Text(next).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
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
                Image(systemName: item.kind == .albums ? "opticaldisc" : "person.crop.circle").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
#endif
