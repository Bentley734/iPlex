import SwiftUI

struct NowPlayingPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showing: Bool

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.13), value: showing)
    }
}

struct NowPlayingPopTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.zIndex(1).clipShape(Rectangle())
            .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
    }
}

struct NowPlayingView: View {
    @ObservedObject var library: LibraryModel
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @State private var showingQueue = false
    @State private var showingArtwork = false
    @State private var showingLyrics = false
    @State private var showingSignalPath = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let close: () -> Void

    private var palette: ArtworkPalette? { artworkColors ? library.playingPalette : nil }
    private var accent: Color { theme.accent(using: palette) }
    private var duration: Double { max(0, library.state.duration) }
    private var elapsed: Double { min(duration, max(0, library.state.elapsed)) }

    private var currentTrack: LiveTrack? {
        guard let index = library.state.index, library.playingTracks.indices.contains(index) else { return nil }
        return library.playingTracks[index]
    }

    var body: some View {
        GeometryReader { geometry in
            let queueWidth = min(340, max(128, geometry.size.width * 0.43))
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, min(60, geometry.size.width * 0.045))
                    .musicGlass(theme, radius: 20)
                    .padding(theme.usesLiquidGlass ? 8 : 0)
                HStack(spacing: 0) {
                    player
                    if showingQueue {
                        queuePanel(compact: queueWidth < 235)
                            .frame(width: queueWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                .clipped()
            }
        }
        .background {
            theme.backdrop(using: palette)
                .overlay {
                    if !theme.keepsBlackCanvas {
                        RadialGradient(colors: [accent.opacity(0.17), .clear], center: .topLeading,
                                       startRadius: 0, endRadius: 950)
                    }
                }
                .ignoresSafeArea()
        }
        .accessibilityHidden(showingArtwork)
        .disabled(showingArtwork)
        .overlay {
            if showingArtwork, let album = library.playingAlbum {
                expandedArtwork(album)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingArtwork)
        .onChange(of: library.playingAlbum == nil) { _, ended in
            if ended { showingArtwork = false }
        }
        .tint(accent)
        .sheet(isPresented: $showingLyrics) {
            NowPlayingLyrics(library: library).musicSheet(theme).preferredColorScheme(theme.scheme).tint(accent)
        }
        .sheet(isPresented: $showingSignalPath) {
            signalPath.musicSheet(theme)
        }
        #if os(tvOS)
        .onExitCommand {
            if showingArtwork { showingArtwork = false }
            else { close() }
        }
        #endif
    }

    private var header: some View {
        HStack {
            Button("Library", systemImage: "chevron.backward", action: close)
                #if !os(tvOS)
                .keyboardShortcut(.cancelAction)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Now Playing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Button("Queue", systemImage: "list.bullet") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showingQueue.toggle() }
            }
                .musicGlass(theme, radius: 12, interactive: true)
                .tint(showingQueue ? accent : nil)
                .accessibilityAddTraits(showingQueue ? .isSelected : [])
                .disabled(library.playingTracks.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .buttonStyle(.bordered)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var player: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 650
            let compact = geometry.size.width < 300 || (showingQueue && geometry.size.height < 405)
            let inset = wide ? min(68, geometry.size.width * 0.045) : (compact ? 10 : 24)
            let coverWidth = wide
                ? min(680, geometry.size.width * 0.47, max(220, geometry.size.height - 60))
                : min(460, geometry.size.width - inset * 2, max(130, geometry.size.height * (showingQueue ? 0.35 : 0.53)))
            ScrollView {
                if let album = library.playingAlbum {
                    let layout = wide
                        ? AnyLayout(HStackLayout(alignment: .center, spacing: min(78, geometry.size.width * 0.055)))
                        : AnyLayout(VStackLayout(alignment: .center, spacing: compact ? 12 : 26))
                    layout {
                        Button { showingArtwork = true } label: {
                            artwork(album)
                                .frame(width: max(1, coverWidth), height: max(1, coverWidth))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enlarge album artwork")
                        playback(album, compact: compact)
                            .padding(theme.usesLiquidGlass ? (compact ? 8 : 16) : 0)
                            .musicGlass(theme, radius: 22)
                            .frame(maxWidth: 510, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, inset)
                    .padding(.vertical, wide ? 30 : (compact ? 10 : 22))
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                } else {
                    Text("Nothing playing")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func queuePanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(compact ? 10 : 18)
            ScrollViewReader { scroll in
                ScrollView {
                    queue(compact: compact)
                        .padding(.horizontal, compact ? 5 : 12)
                }
                .onAppear {
                    if let track = currentTrack { scroll.scrollTo(track.id, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(theme.usesLiquidGlass ? .clear : theme.surface(using: palette))
        .overlay(alignment: .leading) {
            if !theme.usesLiquidGlass { Divider().opacity(0.5) }
        }
        .musicGlass(theme, radius: 20)
        .padding(theme.usesLiquidGlass ? 8 : 0)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func artwork(_ album: MusicEntry) -> some View {
        Color.primary.opacity(0.08)
            .overlay { artworkImage(album, fit: false) }
            .clipShape(.rect(cornerRadius: 19))
            .shadow(color: .black.opacity(0.3), radius: 15, y: 7)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func artworkImage(_ album: MusicEntry, fit: Bool) -> some View {
        if let image = library.playingArtwork {
            #if os(macOS)
            let cover = Image(nsImage: image)
            #else
            let cover = Image(uiImage: image)
            #endif
            cover.resizable().aspectRatio(contentMode: fit ? .fit : .fill)
        } else if album.kind != .playlists {
            PlexArtwork(item: album, library: library) { artworkPlaceholder }
        } else {
            artworkPlaceholder
        }
    }

    private func expandedArtwork(_ album: MusicEntry) -> some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Button { showingArtwork = false } label: {
                artworkImage(album, fit: true)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(13)
                            .background(.black.opacity(theme.usesLiquidGlass ? 0.25 : 0.72), in: Circle())
                            .musicGlass(theme, radius: 24, interactive: true)
                            .padding(16)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close album artwork")
            #if !os(tvOS)
            .keyboardShortcut(.cancelAction)
            #endif
        }
        .background(.black)
        .transition(.opacity)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note").font(.largeTitle).foregroundStyle(accent)
    }

    private func playback(_ album: MusicEntry, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 15) {
            Text(currentTrack?.title ?? (library.state.title.isEmpty ? album.title : library.state.title))
                .font(compact ? .headline : .largeTitle.bold()).lineLimit(compact ? 2 : 3)
            let artist = currentTrack?.artist ?? album.artist
            if !artist.isEmpty { Text(artist).font(compact ? .caption : .title3).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2) }
            if let release = currentTrack?.album ?? (album.kind == .albums ? album.title : nil) {
                Text(release).font(compact ? .caption2 : .subheadline).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
            ViewThatFits(in: .horizontal) {
                HStack { playbackTools }
                VStack(alignment: .leading) { playbackTools }
            }
            .buttonStyle(.bordered)
            if !library.state.message.isEmpty {
                Text(library.state.message).font(.callout).foregroundStyle(accent)
            }
            VStack(spacing: 6) {
                #if os(tvOS)
                ProgressView(value: elapsed, total: max(1, duration)).accessibilityLabel("Playback position")
                #else
                Slider(value: Binding(get: { elapsed }, set: library.player.seek),
                       in: 0...max(1, duration))
                    .disabled(duration <= 0).accessibilityLabel("Playback position")
                #endif
                HStack {
                    Text(clock(elapsed))
                    Spacer()
                    Text(clock(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack(spacing: compact ? 5 : 14) {
                Spacer(minLength: 0)
                Button("Previous Track", systemImage: "backward.end.fill", action: library.player.previous)
                    .disabled(!library.state.previous)
                #if os(tvOS)
                Button("Back 15 Seconds", systemImage: "gobackward.15") { library.player.seek(to: max(0, elapsed - 15)) }
                    .disabled(duration <= 0)
                #endif
                Button(library.state.playing ? "Pause" : "Play",
                       systemImage: library.state.playing ? "pause.fill" : "play.fill", action: library.player.toggle)
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .regular : .large)
                #if os(tvOS)
                Button("Forward 15 Seconds", systemImage: "goforward.15") { library.player.seek(to: min(duration, elapsed + 15)) }
                    .disabled(duration <= 0)
                #endif
                Button("Next Track", systemImage: "forward.end.fill", action: library.player.next)
                    .disabled(!library.state.next)
                Spacer(minLength: 0)
            }
            .font(.title2)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            #if !os(tvOS)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").accessibilityHidden(true)
                Slider(value: Binding(get: { library.playbackVolume }, set: library.changePlaybackVolume), in: 0...1)
                    .accessibilityLabel("Playback volume")
                Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder private var playbackTools: some View {
        if let track = currentTrack {
            Button(track.format.badge, systemImage: "waveform.path") { showingSignalPath = true }
                .accessibilityHint("Shows audio signal path")
        }
        Button("Lyrics", systemImage: "quote.bubble") { showingLyrics = true }
            .disabled(currentTrack?.plexID == nil)
    }

    private var signalPath: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Signal Path").font(.title.bold())
                Spacer()
                Button("Done") { showingSignalPath = false }
            }
            LabeledContent("Plex source", value: currentTrack?.format.details.isEmpty == false
                ? currentTrack?.format.details ?? "" : "Format details unavailable")
            LabeledContent("Playback", value: "Direct stream · AVFoundation")
            LabeledContent("Equalizer", value: library.equalizer.isFlat ? "Flat" :
                library.equalizerAvailable == false ? "Unavailable" :
                library.equalizerAvailable == true ? "Active" : "Configured")
            LabeledContent("Output", value: library.player.outputDescription)
        }
        .monospacedDigit()
        .padding(28)
        #if os(macOS)
        .frame(minWidth: 470)
        #endif
        #if os(tvOS)
        .onExitCommand { showingSignalPath = false }
        #endif
    }

    private func queue(compact: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(Array(library.playingTracks.enumerated()), id: \.element.id) { index, track in
                queueRow(track, index: index, compact: compact)
                    .id(track.id)
            }
        }
        .padding(.bottom, 16)
    }

    private func queueRow(_ track: LiveTrack, index: Int, compact: Bool) -> some View {
        let current = index == library.state.index
        return HStack(spacing: compact ? 4 : 8) {
            #if !os(tvOS)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: compact ? 16 : 25, height: 30)
                .contentShape(Rectangle())
                .draggable(track.id.uuidString)
                .accessibilityHidden(true)
            #endif
            Button { library.player.selectTrack(index) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).lineLimit(1)
                    if let artist = track.artist { Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            #if os(tvOS)
            .buttonStyle(.bordered)
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityAddTraits(current ? .isSelected : [])
            if !compact, let length = track.duration { Text(clock(length)).font(.caption.monospacedDigit()) }
            Menu {
                if index > 0 {
                    Button("Move Up", systemImage: "arrow.up") {
                        move(track.id, by: -1)
                    }
                }
                if index + 1 < library.playingTracks.count {
                    Button("Move Down", systemImage: "arrow.down") {
                        move(track.id, by: 1)
                    }
                }
                Button("Remove from Queue", systemImage: "trash", role: .destructive) {
                    library.player.removeQueuedTrack(track.id)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Queue actions for " + track.title)
            #if os(macOS)
            .menuIndicator(.hidden)
            #endif
        }
        .padding(compact ? 4 : 9)
        .foregroundStyle(current ? accent : .primary)
        .background(current ? accent.opacity(theme.usesLiquidGlass ? 0.25 : 0.16) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if theme.usesLiquidGlass {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(current ? 0.22 : 0.12))
                    .allowsHitTesting(false)
            }
        }
        #if !os(tvOS)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let id = UUID(uuidString: value), id != track.id,
                  library.playingTracks.contains(where: { $0.id == id }) else { return false }
            library.player.moveQueuedTrack(id, to: track.id)
            return true
        }
        #endif
    }

    private func move(_ id: UUID, by offset: Int) {
        let queue = library.playingTracks
        guard let index = queue.firstIndex(where: { $0.id == id }), queue.indices.contains(index + offset) else { return }
        library.player.moveQueuedTrack(id, to: queue[index + offset].id)
    }

    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(359_999, max(0, seconds))) : 0
        return value < 3_600 ? String(format: "%d:%02d", value / 60, value % 60) :
            String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
    }
}

private struct NowPlayingLyrics: View {
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lines: [MusicLyricLine] = []
    @State private var message = "Loading lyrics…"

    private var active: Int? {
        lines.last { line in
            guard let time = line.time else { return false }
            return time <= library.state.elapsed
        }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Lyrics").font(.title.bold())
                    if let track = library.currentTrack { Text(track.title).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            if lines.isEmpty {
                Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(lines) { line in
                                if let time = line.time {
                                    Button { library.player.seek(to: time) } label: { lyric(line) }
                                        #if os(tvOS)
                                        .buttonStyle(.bordered)
                                        #else
                                        .buttonStyle(.plain)
                                        #endif
                                        .id(line.id)
                                } else {
                                    lyric(line)
                                }
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .onChange(of: active, initial: true) { _, line in
                        if let line {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                                scroll.scrollTo(line, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .padding(26)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 450)
        #endif
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .task(id: library.currentTrack?.id) {
            lines = []
            message = "Loading lyrics…"
            guard let track = library.currentTrack else { message = "No track selected."; return }
            do {
                let lyrics = try await library.lyrics(for: track)
                guard !Task.isCancelled else { return }
                lines = lyrics
                message = "Lyrics are unavailable for this track."
            } catch {
                if !Task.isCancelled { message = "Couldn’t load lyrics from Plex." }
            }
        }
    }

    private func lyric(_ line: MusicLyricLine) -> some View {
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.title2.weight(active == line.id ? .bold : .medium))
            .foregroundStyle(active == nil || active == line.id ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LibraryQueueActions: View {
    let library: LibraryModel
    let entry: MusicEntry
    var track: LiveTrack?

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            library.enqueue(entry, track: track, playNext: true)
        }
        Button("Add to Queue", systemImage: "text.append") {
            library.enqueue(entry, track: track, playNext: false)
        }
    }
}

struct PopularTrackBadge: View {
    var body: some View {
        Image(systemName: "flame.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("Popular track")
            .help("Popular track")
    }
}

struct PlexPinButton: View {
    @ObservedObject var library: LibraryModel
    let entry: MusicEntry

    var body: some View {
        if entry.kind.canPin {
            let pinned = library.isPinned(entry)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                library.togglePin(entry)
            }
        }
    }
}

struct PlexLibrarySwitcher: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        if library.libraries.count > 1 {
            Picker("Music Library", selection: Binding(get: { library.libraryID }, set: library.chooseLibrary)) {
                if library.libraryID.isEmpty { Text("Choose Library").tag("") }
                ForEach(library.libraries, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel("Switch Music Library")
            .fixedSize()
            .disabled(library.reconnecting)
        }
    }
}

struct PinnedMusicShelf: View {
    @ObservedObject var library: LibraryModel
    let open: (MusicEntry) -> Void

    var body: some View {
        if !library.pins.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Pinned", systemImage: "pin.fill").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 13) {
                        ForEach(library.pins) { entry in
                            Button { open(entry) } label: {
                                HStack(spacing: 9) {
                                    Color.primary.opacity(0.08)
                                        .overlay {
                                            PlexArtwork(item: entry, library: library) {
                                                Image(systemName: entry.kind.symbol).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 42, height: 42)
                                        .clipShape(.rect(cornerRadius: 7))
                                    Text(entry.title).lineLimit(1).frame(maxWidth: 145, alignment: .leading)
                                }
                            }
                            .buttonStyle(.bordered)
                            .contextMenu { PlexPinButton(library: library, entry: entry) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }
}
