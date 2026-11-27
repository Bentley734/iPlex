import SwiftUI
#if os(macOS)
import ToolDriveMac
#else
import ToolDriveMobile
#endif

struct NowPlayingPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PageTransitionStyle.preferenceKey) private var style = PageTransitionStyle.zoom
    let showing: Bool

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : style.animation, value: showing)
    }
}

struct NowPlayingPopTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PageTransitionStyle.preferenceKey) private var style = PageTransitionStyle.zoom

    func body(content: Content) -> some View {
        content.zIndex(1).clipShape(Rectangle())
            .transition(reduceMotion ? .identity : style.presentation)
    }
}

struct NowPlayingView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject private var archive: ToolDriveTransport
    private let archiveMode: Bool
    @State private var showingArchiveEQ = false
    @State private var showingVisualizer = false
    @ObservedObject private var wallpaper = GlassWallpaper.shared
    @MusicAppearance private var theme
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @State private var showingQueue = false
    @State private var showingArtwork = false
    @State private var showingLyrics = false
    @State private var showingSignalPath = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let close: () -> Void

    init(library: LibraryModel, archive: ToolDriveTransport? = nil, close: @escaping () -> Void) {
        self.library = library
        self.archive = archive ?? ToolDriveTransport()
        self.archiveMode = archive != nil
        self.close = close
    }

    private var palette: ArtworkPalette? { artworkColors && !archiveMode ? library.playingPalette : nil }
    private var accent: Color { theme.accent(using: artworkColors ? palette : nil) }
    private var duration: Double { max(0, archiveMode ? archive.duration : library.state.duration) }
    private var elapsed: Double { min(duration, max(0, archiveMode ? archive.elapsed : library.state.elapsed)) }
    private var playing: Bool { archiveMode ? archive.playing : library.state.playing }

    private func seek(_ seconds: Double) {
        if archiveMode { archive.seek(seconds) }
        else { library.player.seek(to: seconds) }
    }

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
                    .padding(8)
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
            theme.backdrop(using: palette, allowsAnimatedGradient: false)
                .animation(!reduceMotion ? .easeInOut(duration: 0.8) : nil,
                           value: palette?.wash(in: theme.scheme))
                .overlay {
                    RadialGradient(colors: [accent.opacity(0.17), .clear], center: .topLeading,
                                   startRadius: 0, endRadius: 950)
                }
                .overlay { glassArtworkBackdrop }
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
        .foregroundStyle(theme.text)
        .tint(accent)
        .sheet(isPresented: $showingLyrics) {
            NowPlayingLyrics(library: library, theme: theme).musicSheet(theme).preferredColorScheme(theme.scheme).tint(accent)
        }
        .sheet(isPresented: $showingArchiveEQ) {
            ArchiveEqualizer(transport: archive)
                .musicSheet(theme)
        }
        .onChange(of: showingVisualizer) { _, active in archive.setVisualizerActive(active) }
        .onDisappear { if showingVisualizer { archive.setVisualizerActive(false) } }
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

    @ViewBuilder private var glassArtworkBackdrop: some View {
        if !archiveMode, !reduceTransparency, wallpaper.image == nil, let image = library.playingArtwork {
            GeometryReader { geometry in
                #if os(macOS)
                let artwork = Image(nsImage: image)
                #else
                let artwork = Image(uiImage: image)
                #endif
                artwork.resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped().scaleEffect(1.12)
                    .saturation(artworkColors ? 1.15 : 0)
                    .blur(radius: 36)
                    .opacity(artworkColors ? 0.31 : 0.22)
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
            Button(archiveMode ? "Tracklist" : "Queue", systemImage: "list.bullet") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showingQueue.toggle() }
            }
                .musicGlass(theme, radius: 12, interactive: true)
                .tint(showingQueue ? accent : nil)
                .accessibilityAddTraits(showingQueue ? .isSelected : [])
                .disabled(archiveMode ? archive.trackTitles.isEmpty : library.playingTracks.isEmpty)
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
                let album = library.playingAlbum
                if archiveMode ? archive.title != nil : album != nil {
                    let layout = wide
                        ? AnyLayout(HStackLayout(alignment: .center, spacing: min(78, geometry.size.width * 0.055)))
                        : AnyLayout(VStackLayout(alignment: .center, spacing: compact ? 12 : 26))
                    layout {
                        if archiveMode {
                            archiveArtwork
                                .frame(width: max(1, coverWidth), height: max(1, coverWidth))
                        } else if let album {
                            Button { showingArtwork = true } label: {
                                artwork(album)
                                    .frame(width: max(1, coverWidth), height: max(1, coverWidth))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Enlarge album artwork")
                        }
                        playback(album, compact: compact)
                            .padding(compact ? 8 : 16)
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
            Text(archiveMode ? "Tracklist" : "Up Next")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(compact ? 10 : 18)
            ScrollViewReader { scroll in
                ScrollView {
                    Group {
                        if archiveMode { archiveTracklist }
                        else { queue(compact: compact) }
                    }
                        .padding(.horizontal, compact ? 5 : 12)
                }
                .onAppear {
                    if let track = currentTrack { scroll.scrollTo(track.id, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .musicGlass(theme, radius: 20)
        .padding(8)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func artwork(_ album: MusicEntry) -> some View {
        Color.primary.opacity(0.08)
            .overlay { artworkImage(album, fit: false) }
            .clipShape(.rect(cornerRadius: 19))
            .shadow(color: Color.black.opacity(0.27), radius: 15, y: 7)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: library.state.playing)
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
                            .background(.black.opacity(0.25), in: Circle())
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

    private func playback(_ album: MusicEntry?, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 15) {
            let title = archiveMode ? archive.title ?? "" : currentTrack?.title ?? (library.state.title.isEmpty ? album?.title ?? "" : library.state.title)
            Text(title).font(compact ? .headline : .largeTitle.bold()).lineLimit(compact ? 2 : 3)
            let artist = archiveMode ? archive.context : currentTrack?.artist ?? album?.artist ?? ""
            if !artist.isEmpty { Text(artist).font(compact ? .caption : .title3).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2) }
            if !archiveMode, let release = currentTrack?.album ?? (album?.kind == .albums ? album?.title : nil) {
                Text(release).font(compact ? .caption2 : .subheadline).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
            ViewThatFits(in: .horizontal) {
                HStack { playbackTools }
                VStack(alignment: .leading) { playbackTools }
            }
            .buttonStyle(.bordered)
            let message = archiveMode ? archive.message : library.state.message
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(accent)
            }
            VStack(spacing: 6) {
                #if os(tvOS)
                ProgressView(value: elapsed, total: max(1, duration)).accessibilityLabel("Playback position")
                #else
                Slider(value: Binding(get: { elapsed }, set: seek),
                       in: 0...max(1, duration))
                    .disabled(duration <= 0).accessibilityLabel("Playback position")
                #endif
                HStack {
                    Text(clock(elapsed))
                    Spacer()
                    Text(clock(duration))
                        .accessibilityLabel("Track duration")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack(spacing: compact ? 5 : 14) {
                Spacer(minLength: 0)
                Button("Previous Track", systemImage: "backward.end.fill", action: archiveMode ? archive.previous : library.player.previous)
                    .disabled(!(archiveMode ? archive.canPrevious : library.state.previous))
                #if os(tvOS)
                Button("Back 15 Seconds", systemImage: "gobackward.15") { seek(max(0, elapsed - 15)) }
                    .disabled(duration <= 0)
                #endif
                Button(playing ? "Pause" : "Play",
                       systemImage: playing ? "pause.fill" : "play.fill",
                       action: archiveMode ? archive.toggle : library.player.toggle)
                    .disabled(archiveMode && !archive.canToggle)
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .regular : .large)
                #if os(tvOS)
                Button("Forward 15 Seconds", systemImage: "goforward.15") { seek(min(duration, elapsed + 15)) }
                    .disabled(duration <= 0)
                #endif
                Button("Next Track", systemImage: "forward.end.fill", action: archiveMode ? archive.next : library.player.next)
                    .disabled(!(archiveMode ? archive.canNext : library.state.next))
                Spacer(minLength: 0)
            }
            .font(.title2)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            #if !os(tvOS)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").accessibilityHidden(true)
                Slider(value: Binding(get: { library.playbackVolume }, set: { value in
                    library.changePlaybackVolume(value)
                    #if !os(macOS)
                    if archiveMode { archive.setPlaybackVolume(value) }
                    #endif
                }), in: 0...1)
                    .accessibilityLabel("Playback volume")
                Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            #endif
        }
    }

    @ViewBuilder private var playbackTools: some View {
        if archiveMode {
            Button("Equalizer", systemImage: "slider.horizontal.3") { showingArchiveEQ = true }
            Button("Visualizer", systemImage: "waveform") { showingVisualizer.toggle() }
                .accessibilityAddTraits(showingVisualizer ? .isSelected : [])
        } else {
            if let track = currentTrack {
                Button(track.format.badge, systemImage: "waveform.path") { showingSignalPath = true }
                    .accessibilityHint("Shows audio signal path")
            }
            Button("Lyrics", systemImage: "quote.bubble") { showingLyrics = true }
                .disabled(currentTrack?.plexID == nil)
        }
    }

    private var archiveArtwork: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if showingVisualizer {
                TimelineView(.animation(minimumInterval: 0.06)) { _ in
                    GeometryReader { proxy in
                        let levels = archive.visualizerLevels()
                        HStack(alignment: .center, spacing: 3) {
                            ForEach(levels.indices, id: \.self) { index in
                                Capsule().fill(accent.opacity(0.85))
                                    .frame(height: max(3, min(1, levels[index]) * proxy.size.height))
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.padding(24)
                }
                .accessibilityLabel("Audio Visualizer")
            } else {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(accent)
            }
        }
        .clipShape(.rect(cornerRadius: 19))
    }

    private var archiveTracklist: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(Array(archive.trackTitles.enumerated()), id: \.offset) { index, title in
                Button {
                    archive.selectTrack(index)
                } label: {
                    HStack {
                        Text(index + 1, format: .number).monospacedDigit().foregroundStyle(.secondary)
                        Text(title).lineLimit(2)
                        Spacer(minLength: 0)
                    }.padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityAddTraits(archive.trackIndex == index ? .isSelected : [])
                .tint(archive.trackIndex == index ? accent : nil)
            }
        }.padding(.bottom, 16)
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
        .foregroundStyle(current ? accent : theme.text)
        .background(current ? accent.opacity(0.25) : Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(current ? 0.22 : 0.12))
                .allowsHitTesting(false)
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

private struct ArchiveEqualizer: View {
    let transport: ToolDriveTransport
    @Environment(\.dismiss) private var dismiss
    @State private var settings = PlaybackEQSettings.flat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Equalizer").font(.title.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                ForEach(PlaybackEQPreset.allCases) { preset in
                    Button(preset.rawValue) { settings = preset.settings(magik: settings.magik) }
                }
            }
            band("Bass", value: $settings.bass)
            band("Mid", value: $settings.mid)
            band("Treble", value: $settings.treble)
            Toggle("Magik", isOn: $settings.magik)
        }
        .padding(28)
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
        .onAppear {
            let (bass, mid, treble, magik) = transport.equalizerValues
            settings = PlaybackEQSettings(bass: bass, mid: mid, treble: treble, magik: magik)
        }
        .onChange(of: settings) { _, value in
            transport.setEqualizer(bass: value.bass, mid: value.mid, treble: value.treble, magik: value.magik)
        }
    }

    private func band(_ label: String, value: Binding<Double>) -> some View {
        #if os(tvOS)
        return HStack {
            Text(label)
            Button { value.wrappedValue -= 1 } label: { Image(systemName: "minus") }
                .accessibilityLabel("Decrease " + label).disabled(value.wrappedValue <= -10)
            Button { value.wrappedValue += 1 } label: { Image(systemName: "plus") }
                .accessibilityLabel("Increase " + label).disabled(value.wrappedValue >= 10)
            Text(String(format: "%+.0f dB", value.wrappedValue)).monospacedDigit()
        }
        #else
        return Slider(value: value, in: -10...10, step: 1) { Text(label) }
        #endif
    }
}

private struct NowPlayingLyrics: View {
    @ObservedObject var library: LibraryModel
    let theme: MusicTheme
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
            .foregroundStyle(active == nil ? theme.text : (active == line.id ? theme.accent : theme.text.opacity(0.68)))
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
        Button("Download", systemImage: "arrow.down.circle") {
            library.downloadMusic(entry, track: track)
        }
        if let trackID = track?.plexID ?? (entry.kind == .tracks ? entry.id : nil) {
            Button("Add to Playlist", systemImage: "text.badge.plus") {
                library.editPlaylist(track: trackID, trackTitle: track?.title ?? entry.title)
            }.disabled(!library.canEditPlaylists)
        }
    }
}

struct PlaylistTrackEditing: ViewModifier {
    @ObservedObject var library: LibraryModel
    let track: LiveTrack
    @State private var dropTarget = false

    @ViewBuilder func body(content: Content) -> some View {
        if library.playlistTrackEditable(track) {
            HStack(spacing: 8) {
                #if !os(tvOS)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 32)
                    .contentShape(Rectangle())
                    .draggable(track.id.uuidString)
                    .allowsHitTesting(!library.savingPlaylistTrack)
                    .accessibilityHidden(true)
                #endif
                content.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    if let index = library.tracks.firstIndex(where: { $0.id == track.id }) {
                        if index > 0 {
                            Button("Move Up", systemImage: "arrow.up") {
                                move(by: -1)
                            }
                        }
                        if index + 1 < library.tracks.count {
                            Button("Move Down", systemImage: "arrow.down") {
                                move(by: 1)
                            }
                        }
                    }
                    Button("Remove from Playlist", systemImage: "trash", role: .destructive) {
                        library.changePlaylistTrack(track.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Playlist actions for " + track.title)
                .disabled(library.savingPlaylistTrack || library.busy)
            }
            #if !os(tvOS)
            .contentShape(Rectangle())
            .background(dropTarget ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: String.self) { values, _ in
                guard let first = values.first, let source = UUID(uuidString: first) else { return false }
                return library.changePlaylistTrack(source, to: track.id)
            } isTargeted: { dropTarget = $0 }
            #endif
        } else {
            content
        }
    }
    private func move(by offset: Int) {
        guard let index = library.tracks.firstIndex(where: { $0.id == track.id }),
              library.tracks.indices.contains(index + offset) else { return }
        library.changePlaylistTrack(track.id, to: library.tracks[index + offset].id)
    }

}

struct PlexPlaylistChoice: Identifiable {
    let id: String
    let title: String
}

struct PlexPlaylistEdit: Identifiable {
    let id = UUID()
    let server: String
    let library: String
    let track: String?
    let trackTitle: String
}

struct PlexPlaylistEditor: View {
    @ObservedObject var library: LibraryModel
    let edit: PlexPlaylistEdit

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlexPlaylistChoice] = []
    @State private var name = ""
    @State private var loadError: String?
    @State private var message: String?
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.track == nil ? "New Playlist" : "Add to Playlist").font(.title2.bold())
            if edit.track != nil { Text(edit.trackTitle).foregroundStyle(.secondary) }
            if saved {
                Button("Done") { dismiss() }
            } else {
                if edit.track != nil {
                    if loading { ProgressView("Finding playlists…") }
                    else if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                        Button("Retry Playlists") { refresh += 1 }
                    } else if playlists.isEmpty {
                        Text("No editable music playlists on this server.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(playlists) { playlist in
                                    Button(playlist.title) { save(to: playlist) }
                                        .disabled(saving)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxHeight: 240)
                    }
                }
                HStack {
                    TextField("Playlist name", text: $name)
                        #if !os(tvOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    Button("Create Playlist") { save(to: nil) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
                }
                .disabled(saving)
                Button("Cancel") { dismiss() }.disabled(saving)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if saving { ProgressView("Saving to Plex…") }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 420)
        #endif
        .interactiveDismissDisabled(saving)
        .task(id: refresh) {
            guard edit.track != nil else { loading = false; return }
            loading = true
            loadError = nil
            defer { loading = false }
            do { playlists = try await library.service.editableMusicPlaylists(server: edit.server) }
            catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }

    private func save(to playlist: PlexPlaylistChoice?) {
        guard !saving, !saved, library.serverID == edit.server, library.libraryID == edit.library else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                try await library.service.saveMusicPlaylist(server: edit.server, track: edit.track,
                                                            playlist: playlist?.id, title: name)
                message = playlist.map { "Added to \($0.title)." } ?? "Playlist created."
                saved = true
                library.playlistDidChange(edit, playlist: playlist?.id)
            } catch { message = error.localizedDescription }
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
                            .glassHover(lift: true)
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
