#if os(macOS)
import AppKit
import SwiftUI

@main
struct MusicRoomApp: App {
    @StateObject private var model = LibraryModel()
    @StateObject private var updates = MacAppUpdates()
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(AppIconChoice.preferenceKey) private var iconStyle = AppIconChoice.defaultChoice.rawValue

    init() { MacAppUpdates.recordLaunchingProcess() }

    var body: some Scene {
        WindowGroup {
            MusicWindow(model: model)
                .environmentObject(updates)
                .frame(minWidth: 780, minHeight: 540)
                .preferredColorScheme(theme.scheme)
                .task { updates.acknowledgeLaunch(); applyIcon(); model.restore() }
                .onChange(of: iconStyle) { _, _ in applyIcon() }
        }
        .defaultSize(width: 1120, height: 750)
        .commands {
            CommandMenu("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(MusicTheme.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
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

private struct MusicWindow: View {
    @ObservedObject var model: LibraryModel
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @State private var showSettings = false
    @State private var showVolume = false
    @State private var showPlexifyDeck = true
    @State private var showCompactDeck = false
    @State private var miniPlayer = MacMiniPlayer()
    private var copper: Color { theme.accent }
    private var slate: Color { theme.surface }
    private var graphite: Bool { theme == .graphite }
    private var plexify: Bool { theme == .plexify }

    var body: some View {
        Group {
            if plexify {
                plexifyWorkspace
            } else if graphite {
                HStack(spacing: 0) {
                    sidebar.frame(width: 206)
                    Divider()
                    VStack(spacing: 0) {
                        mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        graphiteTransport
                            .padding(.horizontal, 23).padding(.bottom, 17).padding(.top, 7)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 216)
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                        mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    transport
                }
            }
        }
        .background(theme.backdrop)
        .sheet(isPresented: $showSettings) { MusicSettings(library: model) }
        .tint(copper)
        .onChange(of: model.query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { model.browse() }
            }
        }
    }

    private var plexifyWorkspace: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1040
            VStack(spacing: 1) {
                HStack(spacing: 20) {
                    HeaderBrand(mark: headerMark, theme: theme, width: 155, height: 42)
                    librarySearch.frame(maxWidth: 460).disabled(model.libraryID.isEmpty)
                    Spacer(minLength: 4)
                    Button {
                        if wide { showPlexifyDeck.toggle() }
                        else { showCompactDeck.toggle() }
                    } label: { Label("Now Playing", systemImage: "rectangle.trailingthird.inset.filled") }
                    .popover(isPresented: $showCompactDeck) {
                        plexifyDeck.frame(width: 250, height: 370)
                    }
                    settingsButton
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(slate)
                HStack(spacing: 1) {
                    sidebar.frame(width: 178)
                    mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide && showPlexifyDeck { plexifyDeck.frame(width: 224) }
                }
                graphiteTransport
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.black.opacity(0.23))
        }
    }

    private var plexifyDeck: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Now Playing", systemImage: "waveform")
                    .font(.headline).foregroundStyle(copper)
                if let album = model.playingAlbum {
                    CoverArt(item: album, model: model).aspectRatio(1, contentMode: .fit)
                    Text(model.state.title.isEmpty ? album.title : model.state.title)
                        .font(.title2.bold()).lineLimit(3)
                    if !album.artist.isEmpty {
                        Text(album.artist).foregroundStyle(.secondary)
                    }
                    Text(album.title).font(.caption).foregroundStyle(.secondary)
                    if let next = model.state.nextTitle {
                        Divider()
                        Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(copper)
                        Text(next).font(.callout).lineLimit(2)
                    }
                } else {
                    Text("Nothing playing").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(slate)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !plexify { HeaderBrand(mark: headerMark, theme: theme, width: 155, height: 46) }
                if graphite {
                    librarySearch
                        .disabled(model.libraryID.isEmpty)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if graphite || plexify {
                        Text("Plex library")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10).padding(.bottom, 3)
                    }
                    ForEach(model.visibleKinds, id: \.self) { tab($0) }
                }
                if model.connected {
                    VStack(alignment: .leading, spacing: 10) {
                        if !model.servers.isEmpty {
                            Picker("Server", selection: Binding(get: { model.serverID }, set: model.chooseServer)) {
                                Text("Choose server").tag("")
                                ForEach(model.servers, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                        if !model.libraries.isEmpty {
                            Picker("Library", selection: Binding(get: { model.libraryID }, set: model.chooseLibrary)) {
                                Text("Choose library").tag("")
                                ForEach(model.libraries, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    .labelsHidden()
                }
                if !graphite && !plexify { settingsButton }
                if graphite {
                    Divider()
                    settingsButton
                }
                if model.connected {
                    Button("Disconnect Plex", action: model.disconnect)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(graphite || plexify ? 16 : 24)
        }
        .background(slate)
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    private var librarySearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(model.kind.rawValue.lowercased())", text: $model.query)
                .textFieldStyle(.plain)
        }
        .padding(9)
        .background(graphite || plexify ? .white.opacity(0.06) : slate, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tab(_ kind: MusicKind) -> some View {
        Button {
            searchTask?.cancel()
            model.selectKind(kind)
        } label: {
            Label(kind.rawValue, systemImage: kind.symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11).padding(.vertical, 10)
                .foregroundStyle(model.kind == kind ? copper : .primary)
                .background(model.kind == kind ? copper.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(model.libraryID.isEmpty)
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.libraryID.isEmpty {
                welcome
            } else {
                HStack(spacing: 15) {
                    if model.selectedDetail != nil || model.selectedGroup != nil {
                        Button {
                            if model.selectedDetail != nil { model.closeDetail() }
                            else { model.browse() }
                        } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                    }
                    Text(model.selectedDetail?.title ?? model.selectedGroup?.title ?? model.kind.rawValue)
                        .font(.system(size: graphite ? 38 : 31, weight: .bold, design: graphite ? .rounded : .default))
                        .lineLimit(1)
                    Spacer()
                    if !graphite && !plexify && model.selectedDetail == nil && model.selectedGroup == nil {
                        librarySearch.frame(width: 205)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(copper).padding(.horizontal, 28).padding(.bottom, 12)
                }
                if let album = model.selectedDetail { albumDetail(album) }
                else { grid }
            }
        }
    }

    private var welcome: some View {
        Group {
            if graphite {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(model.connected ? "Choose a music library" : "Your Plex library")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text(model.connected ? "Choose a server and library in the sidebar." :
                             "Connect to Plex to play music from your collection.")
                            .foregroundStyle(.secondary)
                        connectionControls
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    studioDisc.frame(width: 152, height: 152)
                        .padding(.leading, 20)
                        .accessibilityHidden(true)
                }
                .padding(32)
                .background(studioCard)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                standardWelcome
            }
        }
    }

    private var standardWelcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "record.circle")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(copper)
                .accessibilityHidden(true)
            Text(model.connected ? "Choose your music library" : "Your music. Your server.")
                .font(.system(size: 38, weight: .bold))
            Text(model.connected ? "Select a Plex server and a music library in the sidebar." :
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
        } else if model.servers.isEmpty {
            Button("Refresh Servers", action: model.restore)
        }
    }

    private var studioCard: some View {
        RoundedRectangle(cornerRadius: 21)
            .fill(LinearGradient(colors: [copper.opacity(0.13), slate, .black.opacity(0.21)],
                                 startPoint: .topTrailing, endPoint: .bottomLeading))
            .overlay {
                RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.11))
            }
    }

    private var studioDisc: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [slate, .black], startPoint: .top, endPoint: .bottom))
            ForEach([24.0, 40, 56, 69], id: \.self) { inset in
                Circle().strokeBorder(copper.opacity(0.22)).padding(inset / 2)
            }
            Circle().fill(copper).frame(width: 35, height: 35)
            Circle().fill(slate).frame(width: 7, height: 7)
        }
        .overlay { Circle().strokeBorder(.white.opacity(0.15)) }
        .shadow(color: .black.opacity(0.50), radius: 15, y: 8)
    }

    private func studioFeature(_ album: MusicEntry) -> some View {
        HStack(spacing: 23) {
            VStack(alignment: .leading, spacing: 9) {
                Label("From your library", systemImage: "opticaldisc")
                    .font(.caption.weight(.semibold)).foregroundStyle(copper)
                Text(album.title).font(.system(size: 27, weight: .bold, design: .rounded)).lineLimit(2)
                if !album.artist.isEmpty {
                    Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("View album", systemImage: "arrow.up.right") { model.open(album) }
                    .buttonStyle(.bordered).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CoverArt(item: album, model: model).frame(width: 146, height: 146)
                .shadow(color: .black.opacity(0.5), radius: 13, y: 6)
        }
        .padding(22)
        .background(studioCard)
    }

    private var grid: some View {
        ScrollView {
            if plexify && model.selectedGroup == nil && [.albums, .artists].contains(model.kind) && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let entry = model.entries.first {
                PlexifyFeature(item: entry, library: model) { model.open(entry) }
                    .padding(.horizontal, 28).padding(.bottom, 15)
            }
            if graphite && model.kind == .albums && model.selectedGroup == nil &&
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let album = model.entries.first {
                studioFeature(album)
                    .padding(.horizontal, 28).padding(.bottom, 19)
            }
            if !model.busy && model.entries.isEmpty {
                Text("No matches in this library.").foregroundStyle(.secondary).padding(26)
            }
            let trackList = model.kind == .tracks && model.selectedGroup == nil
            LazyVGrid(columns: [GridItem(trackList ? .flexible() : .adaptive(minimum: graphite ? 133 : 145, maximum: 190), spacing: 21)],
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
                }
                if model.more && !model.busy && model.message == nil {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                        .id(model.entries.count)
                        .onAppear { model.loadMore() }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
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
                    }
                }
                if model.busy { ProgressView("Loading tracks…") }
                if let message = model.message, model.tracks.isEmpty {
                    Button("Retry") { model.open(album) }.help(message)
                }
                ForEach(Array(model.tracks.enumerated()), id: \.offset) { index, track in
                    Button { model.play(at: index) } label: {
                        HStack(spacing: 14) {
                            if model.playingAlbum == album && model.state.index == index {
                                Image(systemName: "waveform").foregroundStyle(copper).frame(width: 30)
                            } else {
                                Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                            }
                            Text(track.title).lineLimit(1)
                            Spacer()
                            if let duration = track.duration { Text(clock(duration)).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
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
        }
        .padding(.horizontal, 22).frame(height: 69)
        .background(slate)
    }

    @ViewBuilder private var miniPlayerButton: some View {
        if let style = miniPlayerStyle.resolve(for: theme), model.playingAlbum != nil {
            Button("Mini-player", systemImage: "macwindow.on.rectangle") {
                if let window = NSApp.keyWindow {
                    miniPlayer.show(library: model, style: style, hiding: window)
                }
            }
        }
    }

    private var graphiteTransport: some View {
        HStack(spacing: 14) {
            transportMetadata.frame(maxWidth: .infinity, alignment: .leading)
            miniPlayerButton
            transportButtons
            HStack(spacing: 9) {
                seekControl
                Text(clock(model.state.elapsed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { showVolume.toggle() } label: { Image(systemName: "speaker.wave.2") }
                    .buttonStyle(.borderless).accessibilityLabel("Volume")
                    .popover(isPresented: $showVolume) {
                        Slider(value: Binding(get: { model.playbackVolume }, set: model.changePlaybackVolume), in: 0...1) {
                            Text("Playback volume")
                        }
                        .frame(width: 185).padding(16)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16).frame(height: 65)
        .background(.gray.opacity(0.16), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.12)) }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private var transportMetadata: some View {
        HStack(spacing: 11) {
            if let album = model.playingAlbum {
                CoverArt(item: album, model: model).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.title.isEmpty ? album.title : model.state.title).font(.headline).lineLimit(1)
                    Text([album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !model.state.message.isEmpty {
                        Text(model.state.message).font(.caption2).foregroundStyle(copper).lineLimit(1)
                    }
                }
            } else {
                if graphite {
                    Image(systemName: "waveform").foregroundStyle(copper)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                }
                Text("Nothing playing").foregroundStyle(.secondary)
            }
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 16) {
            Button { model.player.previous() } label: { Image(systemName: "backward.fill") }
                .disabled(!model.state.previous).accessibilityLabel("Previous")
            Button { model.player.toggle() } label: {
                Image(systemName: model.state.playing ? "pause.fill" : "play.fill").font(.title3)
                    .frame(width: graphite ? 37 : nil, height: graphite ? 37 : nil)
                    .background(graphite ? copper.opacity(0.14) : .clear, in: Circle())
                    .foregroundStyle(graphite ? copper : .primary)
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
