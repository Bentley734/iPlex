import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var library: LibraryModel
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @State private var showingQueue = false
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
                    RadialGradient(colors: [accent.opacity(0.17), .clear], center: .topLeading,
                                   startRadius: 0, endRadius: 950)
                }
                .ignoresSafeArea()
        }
        .tint(accent)
        #if os(tvOS)
        .onExitCommand(perform: close)
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
                        artwork(album)
                            .frame(width: max(1, coverWidth), height: max(1, coverWidth))
                        playback(album, compact: compact)
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
        .background(theme.surface(using: palette))
        .overlay(alignment: .leading) { Divider().opacity(0.5) }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func artwork(_ album: MusicEntry) -> some View {
        Color.primary.opacity(0.08)
            .overlay {
                if let image = library.playingArtwork {
                    #if os(macOS)
                    Image(nsImage: image).resizable().scaledToFill()
                    #else
                    Image(uiImage: image).resizable().scaledToFill()
                    #endif
                } else if album.kind != .playlists {
                    PlexArtwork(item: album, library: library) { artworkPlaceholder }
                } else {
                    artworkPlaceholder
                }
            }
            .clipShape(.rect(cornerRadius: 19))
            .shadow(color: .black.opacity(0.3), radius: 15, y: 7)
            .accessibilityHidden(true)
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
        .background(current ? accent.opacity(0.16) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
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
