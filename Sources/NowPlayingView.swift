import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var library: LibraryModel
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
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
            let wide = geometry.size.width >= 650
            let coverWidth = wide
                ? min(360, geometry.size.width * 0.40, geometry.size.height * 0.62)
                : min(320, geometry.size.width - 48)
            ScrollViewReader { scroll in
                VStack(spacing: 0) {
                    HStack {
                        Button("Library", systemImage: "chevron.backward", action: close)
                            #if !os(tvOS)
                            .keyboardShortcut(.cancelAction)
                            #endif
                        Spacer()
                        Text("Now Playing").font(.headline)
                        Spacer()
                        Button("Queue", systemImage: "list.bullet") { scroll.scrollTo("queue", anchor: .top) }
                            .disabled(library.playingTracks.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 12)
                    .musicGlass(theme, radius: 18)
                    ScrollView {
                        if let album = library.playingAlbum {
                            let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 36)) :
                                AnyLayout(VStackLayout(alignment: .center, spacing: 23))
                            layout {
                                artwork(album)
                                    .frame(width: max(1, coverWidth), height: max(1, coverWidth))
                                playback(album)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 20)
                            queue.id("queue")
                        } else {
                            Text("Nothing playing")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(32)
                        }
                    }
                }
                .frame(maxWidth: 1200)
                .padding(.horizontal, wide ? 32 : 20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(theme.backdrop(using: palette).ignoresSafeArea())
        .tint(accent)
        #if os(tvOS)
        .onExitCommand(perform: close)
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

    private func playback(_ album: MusicEntry) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(currentTrack?.title ?? (library.state.title.isEmpty ? album.title : library.state.title))
                .font(.largeTitle.bold()).lineLimit(3)
            let artist = currentTrack?.artist ?? album.artist
            if !artist.isEmpty { Text(artist).font(.title3).foregroundStyle(.secondary) }
            if let release = currentTrack?.album ?? (album.kind == .albums ? album.title : nil) {
                Text(release).font(.subheadline).foregroundStyle(.secondary)
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
            HStack(spacing: 14) {
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
                    .controlSize(.large)
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

    private var queue: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            Text("Queue").font(.title2.bold()).accessibilityAddTraits(.isHeader).padding(.bottom, 6)
            ForEach(library.playingTracks.indices, id: \.self) { index in
                let track = library.playingTracks[index]
                let current = index == library.state.index
                Button { library.player.selectTrack(index) } label: {
                    HStack(spacing: 12) {
                        Group {
                            if current { Image(systemName: "waveform") }
                            else { Text(String(track.number)).monospacedDigit() }
                        }
                        .frame(width: 29)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).lineLimit(1)
                            if let artist = track.artist { Text(artist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let length = track.duration { Text(clock(length)).font(.caption.monospacedDigit()) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(current ? accent : .primary)
                    .background(current ? accent.opacity(0.16) : Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(.bottom, 20)
    }

    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(359_999, max(0, seconds))) : 0
        return value < 3_600 ? String(format: "%d:%02d", value / 60, value % 60) :
            String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
    }
}
