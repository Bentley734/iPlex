import SwiftUI

enum MusicTheme: String, CaseIterable, Identifiable {
    case copper, classic, classicDark, classicOLED, video, plexify, liquidGlass
    #if os(macOS)
    case graphite
    #endif

    var id: String { rawValue }
    var label: String {
        switch self {
        case .copper: "Copper Groove"
        case .classic: "Classic iPod"
        case .classicDark: "Classic iPod Dark"
        case .classicOLED: "Classic iPod OLED"
        case .video: "iPod Video"
        case .plexify: "Plexify"
        case .liquidGlass: "Liquid Glass"
        #if os(macOS)
        case .graphite: "Graphite Studio"
        #endif
        }
    }
    var scheme: ColorScheme { self == .classic ? .light : .dark }
    var usesLiquidGlass: Bool { self == .liquidGlass || self == .classicDark || self == .classicOLED }
    var keepsBlackCanvas: Bool { self == .classicOLED }
    var supportsGlassWallpaper: Bool { usesLiquidGlass && !keepsBlackCanvas }

    var accent: Color {
        switch self {
        case .copper: Color(red: 1, green: 0.64, blue: 0.44)
        case .classic: Color(red: 0.04, green: 0.34, blue: 0.65)
        case .classicDark: Color(red: 0.72, green: 0.82, blue: 0.95)
        case .classicOLED: Color(red: 0.80, green: 0.87, blue: 0.96)
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
        case .classicDark: Color(red: 0.12, green: 0.13, blue: 0.15)
        case .classicOLED: .black
        case .video: Color(red: 0.09, green: 0.12, blue: 0.18)
        case .plexify: Color(red: 0.075, green: 0.125, blue: 0.155)
        case .liquidGlass: Color(red: 0.12, green: 0.17, blue: 0.28)
        #if os(macOS)
        case .graphite: Color(red: 0.09, green: 0.095, blue: 0.103)
        #endif
        }
    }
    @ViewBuilder var backdrop: some View {
        if keepsBlackCanvas {
            Color.black
        } else if self == .liquidGlass {
            ZStack {
                LinearGradient(colors: [surface, Color(red: 0.04, green: 0.07, blue: 0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color.indigo.opacity(0.82), .clear],
                               center: .topTrailing, startRadius: 16, endRadius: 640)
                RadialGradient(colors: [Color(red: 0.05, green: 0.53, blue: 0.72).opacity(0.52), .clear],
                               center: .bottomLeading, startRadius: 12, endRadius: 580)
                RadialGradient(colors: [Color(red: 0.23, green: 0.53, blue: 0.90).opacity(0.25), .clear],
                               center: UnitPoint(x: 0.24, y: 0.16), startRadius: 16, endRadius: 390)
            }
        } else {
            standardBackdrop
        }
    }

    func accent(using palette: ArtworkPalette?) -> Color {
        palette?.accent(in: scheme) ?? accent
    }

    func surface(using palette: ArtworkPalette?) -> Color {
        keepsBlackCanvas ? surface : (palette?.wash(in: scheme) ?? surface)
    }

    func backdrop(using palette: ArtworkPalette?) -> some View {
        ThemeArtworkBackdrop(theme: self, palette: palette)
    }

    private var standardBackdrop: LinearGradient {
        let end: Color
        switch self {
        case .copper: end = Color(red: 0.075, green: 0.073, blue: 0.085)
        case .classic: end = Color(red: 0.96, green: 0.98, blue: 1)
        case .classicDark: end = Color(red: 0.045, green: 0.05, blue: 0.065)
        case .classicOLED: end = .black
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

private struct ThemeArtworkBackdrop: View {
    let theme: MusicTheme
    let palette: ArtworkPalette?
    @ObservedObject private var wallpaper = GlassWallpaper.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        theme.backdrop.overlay {
            if theme.supportsGlassWallpaper, !reduceTransparency, let image = wallpaper.image {
                GlassWallpaperBackdrop(image: image)
            } else if let palette, !theme.keepsBlackCanvas {
                ArtworkColorWash(palette: palette, scheme: theme.scheme)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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

enum LiquidGlassAppearance {
    static let transparencyKey = "LiquidGlassTransparency"
    static let defaultTransparency = 40.0

    static func density(_ transparency: Double) -> Double {
        1 - min(100, max(0, transparency.isFinite ? transparency : defaultTransparency)) / 100
    }
}

private struct MusicGlassSurface: ViewModifier {
    let theme: MusicTheme
    let radius: CGFloat
    let interactive: Bool
    @AppStorage(LiquidGlassAppearance.transparencyKey) private var transparency = LiquidGlassAppearance.defaultTransparency
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let density = reduceTransparency ? 1 : LiquidGlassAppearance.density(transparency)
        let shape = RoundedRectangle(cornerRadius: radius)
        let edge = 0.38 + (1 - density) * 0.28
        let sheen = (theme.keepsBlackCanvas ? 0.045 : 0.12) * (1.2 - density * 0.45)
        content.background {
            ZStack {
                if reduceTransparency {
                    shape.fill(theme.keepsBlackCanvas ? Color(white: 0.075) : theme.surface)
                } else if theme.keepsBlackCanvas {
                    shape.fill(.ultraThinMaterial).opacity(0.10 + density * 0.32)
                } else if #available(macOS 26, iOS 26, tvOS 26, *) {
                    let variant: Glass = density > 0.65 ? .regular : .clear
                    Color.clear.glassEffect(
                        variant.tint(theme.accent.opacity(0.035 + density * 0.12)).interactive(interactive), in: shape
                    )
                } else {
                    shape.fill(.thinMaterial).opacity(0.42 + density * 0.50)
                }

                shape.fill(theme.surface.opacity(0.08 + density * 0.63))
                shape.fill(.linearGradient(
                    colors: [.white.opacity(sheen), theme.accent.opacity(sheen * 0.2), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                shape.strokeBorder(.linearGradient(
                    stops: [.init(color: .white.opacity(edge), location: 0),
                            .init(color: theme.accent.opacity(edge * 0.56), location: 0.26),
                            .init(color: .white.opacity(0.08), location: 0.54),
                            .init(color: theme.accent.opacity(edge * 0.46), location: 1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                shape.inset(by: 1.25).strokeBorder(.linearGradient(
                    colors: [.white.opacity(0.14), .clear, .black.opacity(0.24)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 1)
            }
            .shadow(color: .black.opacity(theme.keepsBlackCanvas ? 0.18 : 0.26), radius: 12, y: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    @ViewBuilder func musicGlass(_ theme: MusicTheme, radius: CGFloat, interactive: Bool = false) -> some View {
        if theme.usesLiquidGlass {
            modifier(MusicGlassSurface(theme: theme, radius: radius, interactive: interactive))
        } else {
            self
        }
    }

    @ViewBuilder func musicSheet(_ theme: MusicTheme) -> some View {
        if theme.usesLiquidGlass {
            musicGlass(theme, radius: 24)
                .presentationBackground(.clear)
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
        if theme == .classicDark || theme == .classicOLED { return .classicBlack }
        if theme == .video { return .video }
        return nil
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    static let preferenceKey = "LibraryLayout"
    case grid, albumTracks, trackList

    var id: Self { self }
    var label: String {
        switch self {
        case .grid: "Artwork Grid"
        case .albumTracks: "Albums with Tracks"
        case .trackList: "Track List"
        }
    }

    func applies(to kind: MusicKind, inGroup: Bool) -> Bool {
        switch self {
        case .grid: false
        case .albumTracks: kind == .albums || inGroup
        case .trackList: true
        }
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
    @AppStorage(LiquidGlassAppearance.transparencyKey) private var glassTransparency = LiquidGlassAppearance.defaultTransparency
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @AppStorage(ArtworkColorWash.motionPreference) private var animateArtworkColors = true
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(HeaderWordmark.preferenceKey) private var headerWordmark = HeaderWordmark.iplex
    @AppStorage(HeaderMarkSize.preferenceKey) private var headerMarkSize = HeaderMarkSize.medium
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @AppStorage(LibraryLayout.preferenceKey) private var libraryLayout = LibraryLayout.grid
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
                    if theme.usesLiquidGlass { transparencyControl }
                    if theme.supportsGlassWallpaper { GlassWallpaperSettings() }
                    Toggle("Artwork Colors", isOn: $artworkColors)
                        .help("Match the interface to the artwork for the current track.")
                    Toggle("Animate Artwork Colors", isOn: $animateArtworkColors)
                        .disabled(!artworkColors || theme.keepsBlackCanvas)
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
                    HeaderBrand(theme: theme, width: 170, height: 42, allowsCycling: false)
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
                    Picker("Library Layout", selection: $libraryLayout) {
                        ForEach(LibraryLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
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
        .musicSheet(theme)
        .background {
            if !theme.usesLiquidGlass { theme.backdrop(using: palette) }
        }
        .tint(theme.accent(using: palette))
        .preferredColorScheme(theme.scheme)
    }

    private var transparencyControl: some View {
        #if os(tvOS)
        HStack {
            Text("Liquid Glass Transparency")
            Spacer()
            Button("Decrease transparency", systemImage: "minus") { glassTransparency = max(0, glassTransparency - 10) }
                .labelStyle(.iconOnly).disabled(glassTransparency <= 0)
            Text(glassTransparency.formatted(.number.precision(.fractionLength(0))) + "%").monospacedDigit()
            Button("Increase transparency", systemImage: "plus") { glassTransparency = min(100, glassTransparency + 10) }
                .labelStyle(.iconOnly).disabled(glassTransparency >= 100)
        }
        #else
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Liquid Glass Transparency")
                Spacer()
                Text(glassTransparency.formatted(.number.precision(.fractionLength(0))) + "%")
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            Slider(value: $glassTransparency, in: 0...100, step: 5) {
                Text("Liquid Glass Transparency")
            } minimumValueLabel: {
                Text("0%")
            } maximumValueLabel: {
                Text("100%")
            }
            .labelsHidden()
            .accessibilityValue(glassTransparency.formatted(.number.precision(.fractionLength(0))) + "%")
        }
        #endif
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
