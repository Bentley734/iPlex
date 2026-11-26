#if os(macOS)
import AppKit
import SwiftUI

@main
struct MusicRoomApp: App {
    @NSApplicationDelegateAdaptor(MusicAppDelegate.self) private var appDelegate
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
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
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
    @State private var showPlexifyDeck = true
    @State private var showCompactDeck = false
    @State private var miniPlayer = MacMiniPlayer()
    private var palette: ArtworkPalette? { artworkColors ? model.playingPalette : nil }
    private var copper: Color { theme.accent(using: palette) }
    private var slate: Color { theme.surface(using: palette) }
    private var graphite: Bool { theme == .graphite }
    private var plexify: Bool { theme == .plexify }

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
        .tint(copper)
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
            let width = geometry.size.width
            if plexify {
                plexifyWorkspace
            } else if graphite {
                HStack(spacing: 0) {
                    resizableSidebar(availableWidth: width, defaultWidth: 206)
                    VStack(spacing: 0) {
                        mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        graphiteTransport
                            .padding(.horizontal, 23).padding(.bottom, 17).padding(.top, 7)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        resizableSidebar(availableWidth: width, defaultWidth: 216)
                        mainPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .musicGlass(theme, radius: 22)
                            .padding(theme.usesLiquidGlass ? 7 : 0)
                    }
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                    transport
                }
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

    private var plexifyWorkspace: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1040
            VStack(spacing: 1) {
                HStack(spacing: 20) {
                    HeaderBrand(theme: theme, width: 155, height: 42)
                    Spacer(minLength: 4)
                    Button {
                        if wide { showPlexifyDeck.toggle() }
                        else { showCompactDeck.toggle() }
                    } label: { Label("Playing Sidebar", systemImage: "rectangle.trailingthird.inset.filled") }
                    .popover(isPresented: $showCompactDeck) {
                        plexifyDeck.frame(width: 250, height: 370)
                    }
                    if videoSection == nil { librarySearch.frame(width: 230).disabled(model.libraryID.isEmpty) }
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(slate)
                HStack(spacing: 1) {
                    resizableSidebar(availableWidth: geometry.size.width - (wide && showPlexifyDeck ? 224 : 0),
                                     defaultWidth: 178)
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

    private func sidebar(width: CGFloat) -> some View {
        let padding: CGFloat = graphite || plexify ? 16 : 24
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !plexify { HeaderBrand(theme: theme, width: min(155, width - padding * 2), height: 46) }
                    VStack(alignment: .leading, spacing: 6) {
                        sidebarButton("Music", icon: "music.note", selected: videoSection == nil) { videoSection = nil }
                        ForEach(PlexVideoKind.allCases) { videoTab($0) }
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
                if videoSection == nil {
                    PlexLibrarySwitcher(library: model, followsAvailableWidth: true)
                }
                settingsButton
            }
            .padding(.horizontal, padding)
            .padding(.top, 10)
            .padding(.bottom, padding)
        }
        .background(theme.usesLiquidGlass ? .clear : slate)
        .musicGlass(theme, radius: 20)
        .padding(theme.usesLiquidGlass ? 7 : 0)
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var librarySearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(model.kind.rawValue.lowercased())", text: $model.query).disabled(model.reconnecting)
                .textFieldStyle(.plain)
        }
        .padding(9)
        .background(theme.usesLiquidGlass ? .clear : graphite || plexify ? .white.opacity(0.06) : slate,
                    in: RoundedRectangle(cornerRadius: 8))
        .musicGlass(theme, radius: 12)
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
            .foregroundStyle(selected ? copper : .primary)
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
        }.disabled(model.serverID.isEmpty || !model.servers.contains { $0.id == model.serverID })
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let videoSection, !model.serverID.isEmpty {
                PlexVideoBrowser(kind: videoSection, server: model.serverID, service: model.service,
                                 pauseMusic: model.player.pause)
                    .id(model.serverID + videoSection.rawValue)
            } else if model.libraryID.isEmpty {
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
                    if !plexify && (graphite || (model.selectedDetail == nil && model.selectedGroup == nil)) {
                        librarySearch.frame(width: 205)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
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

    private var welcome: some View {
        Group {
            if graphite {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(model.connected ? "Choose a music library" : "Your Plex library")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text(model.connected ? "Choose a server and library in Settings." :
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
            Text(model.connected ? "Choose a Plex server and music library in Settings." :
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
            if model.selectedGroup == nil && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PinnedMusicShelf(library: model) { searchTask?.cancel(); model.open($0) }
                    .padding(.horizontal, 28).padding(.bottom, model.pins.isEmpty ? 0 : 14)
            }
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
            if model.kind == .genres && model.selectedGroup == nil {
                MusicGenreList(library: model) { searchTask?.cancel(); model.open($0) }
                    .padding(.horizontal, 28).padding(.bottom, 24)
            } else if libraryLayout.applies(to: model.kind, inGroup: model.selectedGroup != nil) {
                LibraryAlternateLayout(library: model, layout: libraryLayout)
                    .padding(.horizontal, 28).padding(.bottom, 24)
            } else {
                let trackList = model.kind == .tracks && model.selectedGroup == nil
                let scale = libraryArtworkSize.scale
                let artwork = GridItem.Size.adaptive(minimum: ((graphite ? 133 : 145) * scale).rounded(),
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
        .background(theme.usesLiquidGlass ? .clear : slate)
        .musicGlass(theme, radius: 24)
        .padding(theme.usesLiquidGlass ? 8 : 0)
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
