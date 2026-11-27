import SwiftUI

struct MiniPlayerContent: View {
    @ObservedObject var library: LibraryModel
    let style: MiniPlayerStyle
    let close: () -> Void

    var body: some View {
        if style == .queue {
            QueueMiniPlayer(library: library, close: close)
        } else if style == .desktop98 {
            DesktopMiniPlayer(library: library, close: close)
        } else {
            ClickWheelPlayer(library: library,
                             video: style == .video || style == .videoBlack,
                             blackShell: style == .classicBlack || style == .videoBlack, close: close)
        }
    }
}

private struct DesktopMiniPlayer: View {
    @ObservedObject var library: LibraryModel
    let close: () -> Void
    private let shell = Color(red: 0.82, green: 0.83, blue: 0.78)
    private let screen = Color(red: 0.055, green: 0.10, blue: 0.10)
    private let accent = Color(red: 0.34, green: 0.77, blue: 0.67)

    private var duration: Double { max(1, library.state.duration) }
    private var elapsed: Double { min(duration, max(0, library.state.elapsed)) }

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Label("iPlex Desktop ’98", systemImage: "opticaldisc")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Button("Back to Library", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
                    .foregroundStyle(.white).tint(.white)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.linearGradient(colors: [.init(red: 0.11, green: 0.24, blue: 0.34),
                                                  .init(red: 0.15, green: 0.39, blue: 0.36)],
                                        startPoint: .leading, endPoint: .trailing))

            VStack(alignment: .leading, spacing: 7) {
                artwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(library.currentTrack?.title ?? library.state.title)
                    .font(.headline).lineLimit(1).foregroundStyle(.white)
                Text([library.currentTrack?.artist ?? library.playingAlbum?.artist,
                      library.currentTrack?.album ?? library.playingAlbum?.title]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).lineLimit(1).foregroundStyle(accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(screen)
            .overlay { Rectangle().strokeBorder(.black.opacity(0.6), lineWidth: 2).allowsHitTesting(false) }

            #if os(tvOS)
            ProgressView(value: elapsed, total: duration).accessibilityLabel("Playback position")
            #else
            Slider(value: Binding(get: { elapsed }, set: library.player.seek), in: 0...duration)
                .disabled(library.state.duration <= 0)
                .accessibilityLabel("Playback position")
            #endif
            HStack(spacing: 9) {
                transport("Previous track", "backward.end.fill", action: library.player.previous)
                    .disabled(!library.state.previous)
                transport(library.state.playing ? "Pause" : "Play", library.state.playing ? "pause.fill" : "play.fill",
                          action: library.player.toggle)
                transport("Next track", "forward.end.fill", action: library.player.next)
                    .disabled(!library.state.next)
                Spacer(minLength: 6)
                #if !os(tvOS)
                Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
                Slider(value: Binding(get: { library.playbackVolume }, set: library.changePlaybackVolume), in: 0...1)
                    .frame(maxWidth: 105).accessibilityLabel("Volume")
                #else
                transport("Back 10 seconds", "gobackward.10") { library.player.seek(to: max(0, elapsed - 10)) }
                transport("Forward 10 seconds", "goforward.10") { library.player.seek(to: min(duration, elapsed + 10)) }
                #endif
            }
            HStack {
                Text(library.state.playing ? "Playing" : "Paused")
                Spacer()
                Text("\(clock(elapsed)) / \(clock(library.state.duration))").monospacedDigit()
            }
            .font(.system(.caption, design: .monospaced))
            .padding(7).background(screen).foregroundStyle(accent)
        }
        .padding(9)
        .frame(maxWidth: 520, maxHeight: 580)
        .background(shell)
        .overlay { bevel.allowsHitTesting(false) }
        .foregroundStyle(Color(white: 0.10))
        .tint(Color(red: 0.12, green: 0.35, blue: 0.31))
        .environment(\.colorScheme, .light)
        #if os(tvOS)
        .onExitCommand(perform: close)
        .onPlayPauseCommand { library.player.toggle() }
        #endif
        .onChange(of: library.playingAlbum?.id) { _, id in if id == nil { close() } }
    }

    @ViewBuilder private var artwork: some View {
        if let playingArtwork = library.playingArtwork {
            #if os(macOS)
            Image(nsImage: playingArtwork).resizable().scaledToFit().accessibilityHidden(true)
            #else
            Image(uiImage: playingArtwork).resizable().scaledToFit().accessibilityHidden(true)
            #endif
        } else {
            Image(systemName: "opticaldisc.fill").font(.system(size: 56)).foregroundStyle(accent).accessibilityHidden(true)
        }
    }

    private var bevel: some View {
        Rectangle().strokeBorder(.linearGradient(colors: [.white, .white.opacity(0.85), .black.opacity(0.68)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
    }

    private func transport(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(minWidth: 29, minHeight: 29)
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        .background(shell).overlay { bevel.allowsHitTesting(false) }
        #endif
    }

    private func clock(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 999_999))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct QueueMiniPlayer: View {
    @MusicAppearance private var theme
    @ObservedObject var library: LibraryModel
    let close: () -> Void
    private var accent: Color { theme.accent }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Now Playing").font(.headline)
                Spacer()
                Button("Back to Library", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            if let album = library.playingAlbum {
                Color.white.opacity(0.09).overlay {
                    PlexArtwork(item: album, library: library) {
                        Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(accent)
                    }
                }
                .frame(width: 112, height: 112).clipShape(.rect(cornerRadius: 8))
                Text(library.state.title.isEmpty ? album.title : library.state.title)
                    .font(.headline).lineLimit(1)
                Text([album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 18) {
                Button("Previous", systemImage: "backward.fill", action: library.player.previous)
                    .disabled(!library.state.previous)
                Button(library.state.playing ? "Pause" : "Play",
                       systemImage: library.state.playing ? "pause.fill" : "play.fill", action: library.player.toggle)
                    .disabled(library.playingAlbum == nil)
                Button("Next", systemImage: "forward.fill", action: library.player.next)
                    .disabled(!library.state.next)
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered)
            ProgressView(value: min(max(0, library.state.elapsed), max(1, library.state.duration)),
                         total: max(1, library.state.duration))
                .accessibilityLabel("Playback position")
            Text("Queue").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(library.playingTracks.enumerated()), id: \.offset) { index, track in
                            let current = index == library.state.index
                            Button {
                                library.player.selectTrack(index)
                            } label: {
                                HStack(spacing: 9) {
                                    if current { Image(systemName: "speaker.wave.2.fill") }
                                    else { Text(String(index + 1)).monospacedDigit() }
                                    Text(track.title).lineLimit(1)
                                    Spacer()
                                }
                                .padding(7)
                                .foregroundStyle(current ? accent : .primary)
                                .background(current ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            #if os(tvOS)
                            .buttonStyle(.bordered)
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityAddTraits(current ? .isSelected : [])
                            .id(index)
                        }
                    }
                }
                .onChange(of: library.state.index, initial: true) { _, index in
                    if let index { scroll.scrollTo(index, anchor: .center) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 520, maxHeight: 550)
        .musicGlass(theme, radius: 20)
        .preferredColorScheme(.dark)
        .foregroundStyle(theme.text)
        .tint(accent)
        #if os(tvOS)
        .onExitCommand(perform: close)
        #endif
        .onChange(of: library.playingAlbum?.id) { _, id in if id == nil { close() } }
    }
}

struct ClickWheelPlayer: View {
    @ObservedObject var library: LibraryModel
    let video: Bool
    let blackShell: Bool
    let close: () -> Void

    private enum Key: Hashable { case menu, previous, center, next, play }
    @FocusState private var focusedKey: Key?
    @State private var scrubbing = false
    @State private var gestureStarted = false
    @State private var previousAngle: Double?
    @State private var previewPosition: Double?

    private var shellInk: Color { video || blackShell ? .white : Color(red: 0.17, green: 0.21, blue: 0.26) }
    private var shellColors: [Color] {
        if blackShell { return [Color(white: 0.20), Color(white: 0.075), .black] }
        if video { return [Color(white: 0.23), Color(red: 0.085, green: 0.09, blue: 0.106), .black] }
        return [Color(white: 0.99), Color(red: 0.86, green: 0.88, blue: 0.88), Color(white: 0.73)]
    }
    private var displayInk: Color { video ? Color(red: 0.91, green: 0.96, blue: 1) : Color(red: 0.13, green: 0.24, blue: 0.19) }
    private var displayAccent: Color { video ? Color(red: 0.52, green: 0.83, blue: 1) : Color(red: 0.21, green: 0.38, blue: 0.30) }
    private var duration: Double { library.state.duration.isFinite ? max(0, library.state.duration) : 0 }
    private var position: Double { previewPosition ?? library.state.elapsed }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 635
            let wheelSize = wide ? min(345, geometry.size.width * 0.32, geometry.size.height * 0.60) :
                min(246, geometry.size.width * 0.68, geometry.size.height * 0.44)
            let layout = wide ? AnyLayout(HStackLayout(spacing: 30)) : AnyLayout(VStackLayout(spacing: 17))
            layout {
                display(wide: wide)
                    .frame(maxWidth: wide ? 420 : 318)
                VStack(spacing: 12) {
                    wheel(size: wheelSize)
                    fineControls
                }
            }
            .padding(wide ? 32 : 18)
            #if os(macOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .background {
                RoundedRectangle(cornerRadius: 35)
                    .fill(LinearGradient(colors: shellColors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 35)
                            .strokeBorder(.white.opacity(video || blackShell ? 0.22 : 0.8), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(tvOS)
        .frame(width: 940, height: 560)
        .defaultFocus($focusedKey, .center, priority: .userInitiated)
        #endif
        .onChange(of: library.state.index) { _, _ in resetDrag() }
        .onChange(of: library.playingAlbum?.id) { _, id in
            resetDrag()
            if id == nil { close() }
        }
        #if os(tvOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func display(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Now Playing")
                Spacer()
                if let index = library.state.index {
                    Text("Track \(index + 1)").monospacedDigit()
                }
            }
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(displayAccent)
            Rectangle().fill(displayAccent.opacity(0.3)).frame(height: 1)
            HStack(spacing: 12) {
                cover(size: wide ? 110 : 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.state.title.isEmpty ? (library.playingAlbum?.title ?? "Nothing playing") : library.state.title)
                        .font(wide ? .title2.bold() : .headline).lineLimit(2)
                    if let album = library.playingAlbum {
                        Text([album.artist, album.title].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: min(max(0, position), max(1, duration)), total: max(1, duration))
                .tint(displayAccent).accessibilityLabel("Playback position")
            HStack {
                Text(Self.clock(position))
                Spacer()
                Text(Self.clock(duration))
            }.font(.caption.monospacedDigit())
            if !library.state.message.isEmpty {
                Text(library.state.message).font(.caption2).lineLimit(2)
            }
        }
        .foregroundStyle(displayInk)
        .padding(wide ? 20 : 12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: video ?
                    [Color(red: 0.11, green: 0.17, blue: 0.23), Color(red: 0.045, green: 0.08, blue: 0.115)] :
                    [Color(red: 0.91, green: 0.95, blue: 0.80), Color(red: 0.73, green: 0.83, blue: 0.68)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(displayAccent.opacity(0.5), lineWidth: 1) }
        }
        .padding(video ? 7 : 4)
        .background(video || blackShell ? Color(white: 0.035) : Color(white: 0.43), in: RoundedRectangle(cornerRadius: 16))
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(displayAccent.opacity(0.18))
            if let art = library.playingArtwork {
                #if os(macOS)
                Image(nsImage: art).resizable().scaledToFill()
                #else
                Image(uiImage: art).resizable().scaledToFill()
                #endif
            } else {
                Image(systemName: "music.note").foregroundStyle(displayAccent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }

    private func wheel(size: CGFloat) -> some View {
        let offset = size * 0.36
        let circle = ZStack {
            Circle()
                .fill(LinearGradient(colors: video || blackShell ? [Color(white: 0.21), Color(white: 0.06)] :
                        [Color(white: 0.99), Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                .overlay { Circle().strokeBorder(shellInk.opacity(0.35), lineWidth: 1) }
            key(.menu, text: "MENU", label: "Back to Library", size: size, action: close)
                .offset(y: -offset + size * 0.025)
            key(.previous, symbol: "backward.end.fill", label: "Previous or restart track", size: size,
                action: library.player.previous)
                .offset(x: -offset)
            key(.next, symbol: "forward.end.fill", label: "Next track", size: size, disabled: !library.state.next,
                action: library.player.next)
                .offset(x: offset)
            key(.play, symbol: library.state.playing ? "pause.fill" : "play.fill",
                label: library.state.playing ? "Pause" : "Play", size: size, action: library.player.toggle)
                .offset(y: offset)
            key(.center, symbol: scrubbing ? "timeline.selection" : "speaker.wave.2",
                label: scrubbing ? "Switch wheel to volume" : "Switch wheel to scrub", size: size,
                action: toggleMode)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .foregroundStyle(shellInk)
        #if os(tvOS)
        return circle.focusSection()
        #else
        return circle.simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { drag in
                if !gestureStarted {
                    gestureStarted = true
                    previousAngle = angle(at: drag.startLocation, size: size)
                }
                guard let nextAngle = angle(at: drag.location, size: size), let angle = previousAngle else { return }
                previousAngle = nextAngle
                let delta = Self.shortestTurn(from: angle, to: nextAngle)
                guard abs(delta) <= 0.25 else { return }
                if scrubbing {
                    guard duration > 0 else { return }
                    previewPosition = min(duration, max(0, position + delta * min(120, duration)))
                } else {
                    library.changePlaybackVolume(library.playbackVolume + delta)
                }
            }
            .onEnded { _ in
                if let previewPosition { library.player.seek(to: previewPosition) }
                resetDrag()
                gestureStarted = false
            })
        #endif
    }

    private func key(_ key: Key, text: String? = nil, symbol: String? = nil, label: String, size: CGFloat,
                     disabled: Bool = false, action: @escaping () -> Void) -> some View {
        let center = key == .center
        let active = focusedKey == key
        return Button(action: action) {
            ZStack {
                Circle().fill(center ? shellInk.opacity(video ? 0.15 : 0.11) : .clear)
                if let text { Text(text).font(.system(size: size * 0.053, weight: .bold, design: .monospaced)) }
                if let symbol { Image(systemName: symbol).font(.system(size: size * 0.061, weight: .semibold)) }
            }
            .frame(width: size * (center ? 0.40 : 0.235), height: size * (center ? 0.40 : 0.23))
            .contentShape(Circle())
            .overlay { Circle().strokeBorder(active ? displayAccent : shellInk.opacity(center ? 0.22 : 0), lineWidth: active ? 3 : 1) }
            .opacity(disabled ? 0.36 : 1)
        }
        .buttonStyle(.plain)
        .focused($focusedKey, equals: key)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var fineControls: some View {
        HStack(spacing: 10) {
            Button { adjust(-1) } label: { Image(systemName: "minus") }
                .accessibilityLabel(scrubbing ? "Seek backward 10 seconds" : "Decrease playback volume")
                #if !os(tvOS)
                .keyboardShortcut(.leftArrow, modifiers: [])
                #endif
            Text(scrubbing ? "SCRUB" : "VOL \(Int((library.playbackVolume * 100).rounded()))%")
                .font(.caption.monospaced().weight(.semibold))
                .frame(minWidth: 76)
                .accessibilityLabel(scrubbing ? "Scrub mode" : "Playback volume \(Int((library.playbackVolume * 100).rounded())) percent")
            Button { adjust(1) } label: { Image(systemName: "plus") }
                .accessibilityLabel(scrubbing ? "Seek forward 10 seconds" : "Increase playback volume")
                #if !os(tvOS)
                .keyboardShortcut(.rightArrow, modifiers: [])
                #endif
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .foregroundStyle(shellInk)
        .tint(shellInk)
    }

    private func toggleMode() {
        resetDrag()
        scrubbing.toggle()
    }

    private func resetDrag() {
        previewPosition = nil
        previousAngle = nil
    }

    private func adjust(_ direction: Double) {
        if scrubbing {
            guard duration > 0 else { return }
            library.player.seek(to: min(duration, max(0, position + direction * 10)))
        } else {
            library.changePlaybackVolume(library.playbackVolume + direction * 0.05)
        }
    }

    private func angle(at point: CGPoint, size: CGFloat) -> Double? {
        let x = Double(point.x - size / 2)
        let y = Double(point.y - size / 2)
        let radius = hypot(x, y) / Double(size / 2)
        return (0.48...1.14).contains(radius) ? atan2(y, x) : nil
    }

    static func shortestTurn(from angle: Double, to next: Double) -> Double {
        let difference = next - angle
        return atan2(sin(difference), cos(difference)) / (2 * .pi)
    }

    private static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(999_999, seconds))) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
