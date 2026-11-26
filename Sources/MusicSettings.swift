import SwiftUI

enum MusicTheme: String, CaseIterable, Identifiable {
    case copper, classic, video, plexify, liquidGlass
    #if os(macOS)
    case graphite
    #endif

    var id: String { rawValue }
    var label: String {
        switch self {
        case .copper: "Copper Groove"
        case .classic: "Classic iPod"
        case .video: "iPod Video"
        case .plexify: "Plexify"
        case .liquidGlass: "Liquid Glass"
        #if os(macOS)
        case .graphite: "Graphite Studio"
        #endif
        }
    }
    var scheme: ColorScheme { self == .classic ? .light : .dark }
    var accent: Color {
        switch self {
        case .copper: Color(red: 1, green: 0.64, blue: 0.44)
        case .classic: Color(red: 0.04, green: 0.34, blue: 0.65)
        case .video: Color(red: 0.56, green: 0.80, blue: 1)
        case .plexify: Color(red: 0.48, green: 0.90, blue: 0.88)
        case .liquidGlass: Color(red: 0.67, green: 0.89, blue: 1)
        #if os(macOS)
        case .graphite: Color(red: 1, green: 0.75, blue: 0.45)
        #endif
        }
    }
    var surface: Color {
        switch self {
        case .copper: Color(red: 0.104, green: 0.102, blue: 0.119)
        case .classic: Color(red: 0.84, green: 0.89, blue: 0.94)
        case .video: Color(red: 0.09, green: 0.12, blue: 0.18)
        case .plexify: Color(red: 0.075, green: 0.125, blue: 0.155)
        case .liquidGlass: Color(red: 0.12, green: 0.17, blue: 0.28)
        #if os(macOS)
        case .graphite: Color(red: 0.09, green: 0.095, blue: 0.103)
        #endif
        }
    }
    @ViewBuilder var backdrop: some View {
        if self == .liquidGlass {
            ZStack {
                LinearGradient(colors: [surface, Color(red: 0.04, green: 0.07, blue: 0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color.indigo.opacity(0.58), .clear],
                               center: .topTrailing, startRadius: 20, endRadius: 530)
                RadialGradient(colors: [Color.cyan.opacity(0.25), .clear],
                               center: .bottomLeading, startRadius: 15, endRadius: 460)
            }
        } else {
            standardBackdrop
        }
    }

    func accent(using palette: ArtworkPalette?) -> Color {
        palette?.accent(in: scheme) ?? accent
    }

    func surface(using palette: ArtworkPalette?) -> Color {
        palette?.wash(in: scheme) ?? surface
    }

    func backdrop(using palette: ArtworkPalette?) -> some View {
        backdrop.overlay {
            if let palette {
                ArtworkColorWash(palette: palette, scheme: scheme)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var standardBackdrop: LinearGradient {
        let end: Color
        switch self {
        case .copper: end = Color(red: 0.075, green: 0.073, blue: 0.085)
        case .classic: end = Color(red: 0.96, green: 0.98, blue: 1)
        case .video: end = Color(red: 0.025, green: 0.037, blue: 0.066)
        case .plexify: end = Color(red: 0.035, green: 0.057, blue: 0.078)
        case .liquidGlass: end = surface
        #if os(macOS)
        case .graphite: end = Color(red: 0.055, green: 0.059, blue: 0.068)
        #endif
        }
        return LinearGradient(colors: [surface, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ArtworkColorWash: View {
    static let motionPreference = "AnimateArtworkColors"
    let palette: ArtworkPalette
    let scheme: ColorScheme
    @AppStorage(ArtworkColorWash.motionPreference) private var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if animate && !reduceMotion {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: scenePhase != .active)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 36) * .pi / 18
                    let radius = max(geometry.size.width, geometry.size.height)
                    ZStack {
                        RadialGradient(colors: [palette.wash(in: scheme).opacity(0.95), .clear],
                                       center: UnitPoint(x: 0.34 + 0.18 * cos(phase), y: 0.27 + 0.12 * sin(phase)),
                                       startRadius: 0, endRadius: radius * 0.8)
                        RadialGradient(colors: [palette.accent(in: scheme).opacity(0.17), .clear],
                                       center: UnitPoint(x: 0.72 - 0.16 * cos(phase), y: 0.75 - 0.10 * sin(phase)),
                                       startRadius: 0, endRadius: radius * 0.65)
                    }
                }
            }
        } else {
            LinearGradient(colors: [palette.wash(in: scheme).opacity(0.88), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension View {
    @ViewBuilder func musicGlass(_ theme: MusicTheme, radius: CGFloat, interactive: Bool = false) -> some View {
        if theme == .liquidGlass {
            let shape = RoundedRectangle(cornerRadius: radius)
            if #available(macOS 26, iOS 26, tvOS 26, *) {
                glassEffect(.regular.tint(theme.accent.opacity(0.12)).interactive(interactive), in: shape)
            } else {
                background(.regularMaterial, in: shape)
                    .overlay { shape.strokeBorder(.white.opacity(0.20)).allowsHitTesting(false) }
            }
        } else {
            self
        }
    }
}

enum MiniPlayerStyle: String, CaseIterable, Identifiable {
    static let preferenceKey = "MiniPlayerStyle"
    case automatic, classic, classicBlack, video, videoBlack, queue

    var id: Self { self }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .classic: "Classic iPod"
        case .classicBlack: "Classic iPod Black"
        case .video: "iPod Video"
        case .videoBlack: "iPod Video Black"
        case .queue: "Artwork & Queue"
        }
    }

    func resolve(for theme: MusicTheme) -> Self? {
        guard self == .automatic else { return self }
        if theme == .classic { return .classic }
        if theme == .video { return .video }
        return nil
    }
}

enum LibraryArtworkSize: String, CaseIterable, Identifiable {
    static let preferenceKey = "LibraryArtworkSize"
    case small, medium, large, extraLarge

    var id: Self { self }
    var label: String { self == .extraLarge ? "XL" : rawValue.capitalized }

    var scale: CGFloat {
        switch self {
        case .small: 0.76
        case .medium: 1
        case .large: 1.34
        case .extraLarge: 1.72
        }
    }
}

struct MusicSettings: View {
    @ObservedObject var library: LibraryModel
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @AppStorage(ArtworkColorWash.motionPreference) private var animateArtworkColors = true
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(HeaderWordmark.preferenceKey) private var headerWordmark = HeaderWordmark.iplex
    @AppStorage(HeaderMarkSize.preferenceKey) private var headerMarkSize = HeaderMarkSize.medium
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @AppStorage(LibraryArtworkSize.preferenceKey) private var libraryArtworkSize = LibraryArtworkSize.medium
    @AppStorage(LibraryPageSize.preferenceKey) private var pageSize = LibraryPageSize.standard
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @EnvironmentObject private var updates: MacAppUpdates
    #else
    @State private var showAppIcons = false
    #endif

    private var palette: ArtworkPalette? { artworkColors ? library.playingPalette : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.title.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if library.connected {
                        plexConnection
                        Divider()
                    }
                    Picker("Theme", selection: $theme) {
                        ForEach(MusicTheme.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Toggle("Artwork Colors", isOn: $artworkColors)
                        .help("Match the interface to the artwork for the current track.")
                    Toggle("Animate Artwork Colors", isOn: $animateArtworkColors)
                        .disabled(!artworkColors)
                        .help("Let the album colors drift slowly across the background.")
                    Picker("Mini-player", selection: $miniPlayerStyle) {
                        ForEach(MiniPlayerStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Picker("Header Wordmark", selection: $headerWordmark) {
                        ForEach(HeaderWordmark.allCases) { wordmark in
                            Text(wordmark.label).tag(wordmark)
                        }
                    }
                    Picker("Header Logo", selection: $headerMark) {
                        ForEach(HeaderMark.allCases) { mark in
                            Text(mark.label).tag(mark)
                        }
                    }
                    Picker("Header Logo Size", selection: $headerMarkSize) {
                        ForEach(HeaderMarkSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    HeaderBrand(mark: headerMark, theme: theme, width: 170, height: 42)
                        .accessibilityHidden(true)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App Icon").font(.headline)
                        #if os(macOS)
                        MacAppIconGrid()
                        #else
                        Button("Choose App Icon") { showAppIcons = true }
                        #endif
                    }
                    Divider()
                    Picker("Library Artwork Size", selection: $libraryArtworkSize) {
                        ForEach(LibraryArtworkSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    Picker("Results per Page", selection: $pageSize) {
                        ForEach(LibraryPageSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .onChange(of: pageSize) { _, _ in library.refreshPageSize() }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Library Sections").font(.headline)
                        ForEach(MusicKind.allCases, id: \.self) { kind in
                            Toggle(kind.rawValue, isOn: Binding(
                                get: { library.visibleKinds.contains(kind) },
                                set: { library.setVisibility(kind, visible: $0) }
                            ))
                            .disabled(library.visibleKinds == [kind])
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App Updates").font(.headline)
                        #if os(macOS)
                        Button(updates.buttonTitle, action: updates.act)
                            .disabled(updates.installing)
                        if !updates.status.isEmpty { Text(updates.status).foregroundStyle(.secondary) }
                        #elseif os(iOS)
                        Link("View GitHub Releases", destination: URL(string: "https://github.com/Bentley734/iPlex/releases")!)
                        #else
                        Text("github.com/Bentley734/iPlex/releases").foregroundStyle(.secondary)
                        #endif
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("Equalizer").font(.headline)
                            Spacer()
                            Button("Reset EQ") { library.updateEqualizer(.flat) }
                        }
                        band("Bass", \.bass)
                        band("Midrange", \.mid)
                        band("Treble", \.treble)
                        if library.equalizerAvailable == false {
                            Text("Equalizer is unavailable for this track.").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plex Artwork").font(.headline)
                        if library.libraryID.isEmpty {
                            Text("Choose a Plex music library to cache artwork.").foregroundStyle(.secondary)
                        } else {
                            Text("Save album covers and artist pictures from \(library.libraries.first { $0.id == library.libraryID }?.name ?? "your selected library") to this device.")
                                .foregroundStyle(.secondary)
                            if library.cachingCovers {
                                Button("Cancel Caching", action: library.stopCachingCovers)
                            } else {
                                Button("Cache Library Artwork", action: library.cacheLibraryArtwork)
                            }
                        }
                        if !library.coverCacheStatus.isEmpty {
                            Text(library.coverCacheStatus).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 5)
            }
        }
        .padding(30)
        #if os(macOS)
        .frame(width: 490, height: 560)
        #endif
        #if os(iOS) || os(tvOS)
        .sheet(isPresented: $showAppIcons) { MusicAppIconPicker() }
        #endif
        .background(theme.backdrop(using: palette))
        .tint(theme.accent(using: palette))
        .preferredColorScheme(theme.scheme)
    }

    private var plexConnection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plex Connection").font(.headline)
            if library.servers.isEmpty {
                Button("Refresh Servers", action: library.restore).disabled(library.busy)
            } else {
                Picker("Server", selection: Binding(get: { library.serverID }, set: library.chooseServer)) {
                    Text("Choose server").tag("")
                    ForEach(library.servers, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            if !library.libraries.isEmpty {
                Picker("Music Library", selection: Binding(get: { library.libraryID }, set: library.chooseLibrary)) {
                    Text("Choose library").tag("")
                    ForEach(library.libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            if library.libraryID.isEmpty, let message = library.message {
                Text(message).foregroundStyle(.secondary)
            }
            Button("Disconnect Plex", action: library.disconnect)
        }
    }

    private func band(_ title: String, _ key: WritableKeyPath<PlaybackEQSettings, Double>) -> some View {
        let value = library.equalizer[keyPath: key]
        return HStack {
            Text(title).frame(width: 125, alignment: .leading)
            #if os(tvOS)
            Button { update(value - 1, key) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Decrease " + title).disabled(value <= -10)
            Button { update(value + 1, key) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Increase " + title).disabled(value >= 10)
            #else
            Slider(value: Binding(get: { value }, set: { update($0, key) }), in: -10...10, step: 1) {
                Text(title)
            }.labelsHidden()
            #endif
            Spacer(minLength: 8)
            Text(String(format: "%+.0f dB", value)).monospacedDigit()
        }
    }

    private func update(_ value: Double, _ key: WritableKeyPath<PlaybackEQSettings, Double>) {
        var settings = library.equalizer
        settings[keyPath: key] = value
        library.updateEqualizer(settings)
    }
}
