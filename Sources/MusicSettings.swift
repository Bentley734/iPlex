import SwiftUI

private struct HeaderBrandSettings: View {
    @AppStorage(HeaderMarkSize.preferenceKey) private var markSize = HeaderMarkSize.medium
    private let section: HeaderBrandSection
    private var choices: HeaderBrandChoices
    let theme: MusicTheme

    init(section: HeaderBrandSection, theme: MusicTheme) {
        self.section = section
        choices = HeaderBrandChoices(section: section)
        self.theme = theme
    }

    var body: some View {
        Picker("Header Wordmark", selection: choices.wordmarkSelection) {
            ForEach(HeaderWordmark.choices(for: section)) { Text($0.label).tag($0) }
        }
        Picker("Header Logo", selection: choices.logoSelection) {
            ForEach(HeaderMark.choices(for: section)) { Text($0.label).tag($0) }
        }
        Picker("Header Logo Size", selection: $markSize) {
            ForEach(HeaderMarkSize.allCases) { Text($0.label).tag($0) }
        }
        HeaderBrand(theme: theme, width: 170, height: 42, allowsCycling: false, section: section,
                    mark: choices.logoSelection, wordmark: choices.wordmarkSelection)
            .accessibilityHidden(true)
    }
}
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum LiquidGlassColor {
    static let textKey = "LiquidGlassTextColor"
    static let accentKey = "LiquidGlassAccentColor"
    static let defaultText = "#F2F7FF"
    static let defaultAccent = "#ABE3FF"

    static func hex(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return "#" + digits.uppercased()
    }

    static func color(_ saved: String) -> Color? {
        guard let hex = hex(saved), let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    #if !os(tvOS)
    static func hex(_ color: Color) -> String? {
        #if os(macOS)
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let components = [red, green, blue]
        #endif
        guard components.allSatisfy(\.isFinite) else { return nil }
        let rgb = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
    }
    #endif
}

@propertyWrapper
struct MusicAppearance: DynamicProperty {
    @AppStorage(LiquidGlassColor.textKey) private var text = ""
    @AppStorage(LiquidGlassColor.accentKey) private var accent = ""

    var wrappedValue: MusicTheme { MusicTheme(customText: text, customAccent: accent) }
}

struct MusicTheme {
    let customText: String
    let customAccent: String
    let scheme = ColorScheme.dark
    let surface = Color(red: 0.12, green: 0.17, blue: 0.28)
    var text: Color { LiquidGlassColor.color(customText) ?? Color(red: 242/255, green: 247/255, blue: 1) }
    private var customAccentColor: Color? { LiquidGlassColor.color(customAccent) }
    var accent: Color { customAccentColor ?? Color(red: 171/255, green: 227/255, blue: 1) }

    var backdrop: some View {
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
    }

    func accent(using palette: ArtworkPalette?) -> Color {
        customAccentColor ?? palette?.accent(in: scheme) ?? accent
    }

    func surface(using palette: ArtworkPalette?) -> Color { palette?.wash(in: scheme) ?? surface }

    func backdrop(using palette: ArtworkPalette?, allowsAnimatedGradient: Bool = true) -> some View {
        ThemeArtworkBackdrop(theme: self, palette: palette, allowsAnimatedGradient: allowsAnimatedGradient)
    }
}

private struct ThemeArtworkBackdrop: View {
    let theme: MusicTheme
    let palette: ArtworkPalette?
    let allowsAnimatedGradient: Bool
    @ObservedObject private var wallpaper = GlassWallpaper.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        theme.backdrop.overlay {
            if allowsAnimatedGradient, !reduceTransparency, wallpaper.background == .gradient {
                AnimatedGradientBackdrop()
            } else if !reduceTransparency, let image = wallpaper.image {
                GlassWallpaperBackdrop(image: image, isPreset: wallpaper.background.isPreset)
            } else if let palette {
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

enum LiquidGlassTint: String, CaseIterable, Identifiable {
    static let preferenceKey = "LiquidGlassTint"
    case themeDefault, none, blue, mint, violet, rose, amber

    var id: Self { self }
    var label: String {
        switch self {
        case .themeDefault: "Match Accent"
        case .none: "No Tint"
        default: rawValue.capitalized
        }
    }

    func color(for theme: MusicTheme) -> Color? {
        switch self {
        case .themeDefault: theme.accent
        case .none: nil
        case .blue: Color(red: 0.41, green: 0.70, blue: 1)
        case .mint: Color(red: 0.43, green: 0.93, blue: 0.74)
        case .violet: Color(red: 0.72, green: 0.59, blue: 1)
        case .rose: Color(red: 1, green: 0.53, blue: 0.72)
        case .amber: Color(red: 1, green: 0.73, blue: 0.38)
        }
    }
}

private struct MusicGlassSurface: ViewModifier {
    let theme: MusicTheme
    let radius: CGFloat
    let interactive: Bool
    @AppStorage(LiquidGlassAppearance.transparencyKey) private var transparency = LiquidGlassAppearance.defaultTransparency
    @AppStorage(LiquidGlassTint.preferenceKey) private var tint = LiquidGlassTint.themeDefault
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let density = reduceTransparency ? 1 : LiquidGlassAppearance.density(transparency)
        let shape = RoundedRectangle(cornerRadius: radius)
        let color = tint.color(for: theme)
        let edgeColor = color ?? .white
        let base = tint == .themeDefault ? theme.surface : Color(white: 0.12)
        let edge = 0.38 + (1 - density) * 0.28
        let sheen = 0.12 * (1.2 - density * 0.45)
        content.background {
            ZStack {
                if reduceTransparency {
                    shape.fill(base)
                } else if #available(macOS 26, iOS 26, tvOS 26, *) {
                    let variant: Glass = density > 0.65 ? .regular : .clear
                    let material = color.map { variant.tint($0.opacity(0.04 + density * 0.13)) } ?? variant
                    Color.clear.glassEffect(material.interactive(interactive), in: shape)

                } else {
                    shape.fill(.thinMaterial).opacity(0.42 + density * 0.50)
                }

                shape.fill(base.opacity(0.08 + density * 0.63))
                if let color, !reduceTransparency {
                    shape.fill(color.opacity(0.04 + density * 0.06))
                }
                shape.fill(.linearGradient(
                    colors: [.white.opacity(sheen), edgeColor.opacity(sheen * 0.2), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                shape.strokeBorder(.linearGradient(
                    stops: [.init(color: .white.opacity(edge), location: 0),
                            .init(color: edgeColor.opacity(edge * 0.56), location: 0.26),
                            .init(color: .white.opacity(0.08), location: 0.54),
                            .init(color: edgeColor.opacity(edge * 0.46), location: 1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                shape.inset(by: 1.25).strokeBorder(.linearGradient(
                    colors: [.white.opacity(0.14), .clear, .black.opacity(0.24)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.26), radius: 12, y: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func musicGlass(_ theme: MusicTheme, radius: CGFloat, interactive: Bool = false) -> some View {
        modifier(MusicGlassSurface(theme: theme, radius: radius, interactive: interactive))
            .glassHover(radius: radius, when: interactive)
    }

    func musicSheet(_ theme: MusicTheme) -> some View {
        foregroundStyle(theme.text)
            .musicGlass(theme, radius: 24)
            .presentationBackground(.clear)
    }
}

enum MiniPlayerStyle: String, CaseIterable, Identifiable {
    static let preferenceKey = "MiniPlayerStyle"
    case automatic, classic, classicBlack, video, videoBlack, queue, desktop98

    var id: Self { self }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .classic: "Classic iPod"
        case .classicBlack: "Classic iPod Black"
        case .video: "iPod Video"
        case .videoBlack: "iPod Video Black"
        case .queue: "Artwork & Queue"
        case .desktop98: "Desktop ’98"
        }
    }

    var resolved: Self { self == .automatic ? .queue : self }

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
    static let videoPosterPreferenceKey = "VideoPosterSize"
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

enum VideoSubtitleMode: String, CaseIterable, Identifiable {
    static let preferenceKey = "VideoSubtitleMode"
    case off, automatic

    var id: Self { self }
    var label: String { self == .off ? "Off" : "Automatic" }
}

struct MusicSettings: View {
    @ObservedObject var library: LibraryModel
    @MusicAppearance private var theme
    @AppStorage(LiquidGlassColor.textKey) private var textColor = ""
    @AppStorage(LiquidGlassColor.accentKey) private var accentColor = ""
    @AppStorage(LiquidGlassTint.preferenceKey) private var liquidTint = LiquidGlassTint.themeDefault
    @AppStorage(LiquidGlassAppearance.transparencyKey) private var glassTransparency = LiquidGlassAppearance.defaultTransparency
    @AppStorage(PageTransitionStyle.preferenceKey) private var pageTransitionStyle = PageTransitionStyle.zoom
    #if !os(tvOS)
    @AppStorage(glassHoverPreferenceKey) private var glassHoverEffects = true
    #endif
    @AppStorage(ArtworkPalette.preferenceKey) private var artworkColors = false
    @AppStorage(ArtworkColorWash.motionPreference) private var animateArtworkColors = true
    @State private var headerSection = HeaderBrandSection.music
    @AppStorage(MiniPlayerStyle.preferenceKey) private var miniPlayerStyle = MiniPlayerStyle.automatic
    @AppStorage(LibraryLayout.preferenceKey) private var libraryLayout = LibraryLayout.grid
    @AppStorage(LibraryArtworkSize.preferenceKey) private var libraryArtworkSize = LibraryArtworkSize.medium
    @AppStorage(LibraryArtworkSize.videoPosterPreferenceKey) private var videoPosterSize = LibraryArtworkSize.medium
    @AppStorage(VideoSubtitleMode.preferenceKey) private var subtitleMode = VideoSubtitleMode.off
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
                    plexConnection
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Liquid Glass").font(.headline)
                        GlassColorControl(title: "Text Color", saved: $textColor, defaultHex: LiquidGlassColor.defaultText)
                        GlassColorControl(title: "Accent Color", saved: $accentColor, defaultHex: LiquidGlassColor.defaultAccent)
                    }
                    .foregroundStyle(Color.primary)
                    .tint(.blue)
                    transparencyControl
                    Picker("Liquid Glass Tint", selection: $liquidTint) {
                        ForEach(LiquidGlassTint.allCases) { tint in
                            Text(tint.label).tag(tint)
                        }
                    }
                    GlassWallpaperSettings()
                    Picker("Page Transition", selection: $pageTransitionStyle) {
                        ForEach(PageTransitionStyle.allCases) { effect in Text(effect.label).tag(effect) }
                    }
                    #if !os(tvOS)
                    Toggle("Liquid Glass Hover Effects", isOn: $glassHoverEffects)
                    #endif
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
                    Picker("Customize Header For", selection: $headerSection) {
                        ForEach(HeaderBrandSection.allCases) { section in
                            Text(library.sectionName(section)).tag(section)
                        }
                    }
                    HeaderBrandSettings(section: headerSection, theme: theme)
                        .id(headerSection)
                    #if !os(macOS)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("App Icon").font(.headline)
                        Button("Choose App Icon") { showAppIcons = true }
                    }
                    #endif
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
                    Picker("Movie & TV Poster Size", selection: $videoPosterSize) {
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
                        ForEach(HeaderBrandSection.allCases) { section in
                            LabeledContent(section.title + " name") {
                                TextField(section.title, text: library.customSectionName(section))
                                    .accessibilityLabel(section.title + " name")
                            }
                        }
                        ForEach(MusicKind.allCases, id: \.self) { kind in
                            Toggle(kind.rawValue, isOn: Binding(
                                get: { library.visibleKinds.contains(kind) },
                                set: { library.setVisibility(kind, visible: $0) }
                            ))
                            .disabled(library.visibleKinds == [kind])
                        }
                        ForEach(PlexVideoKind.allCases) { kind in
                            Toggle(kind.title, isOn: Binding(
                                get: { library.visibleVideoKinds.contains(kind) },
                                set: { library.setVisibility(kind, visible: $0) }
                            ))
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Subtitles").font(.headline)
                        Picker("Default Subtitles", selection: $subtitleMode) {
                            ForEach(VideoSubtitleMode.allCases) { mode in Text(mode.label).tag(mode) }
                        }
                        Text("Applies when you start a video. Change available tracks in the player.")
                            .font(.caption).foregroundStyle(.secondary)
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
                        HStack {
                            ForEach(PlaybackEQPreset.allCases) { preset in
                                Button(preset.rawValue) {
                                    library.updateEqualizer(preset.settings(magik: library.equalizer.magik))
                                }
                            }
                        }
                        Toggle("Magik", isOn: Binding(
                            get: { library.equalizer.magik },
                            set: { enabled in
                                var settings = library.equalizer
                                settings.magik = enabled
                                library.updateEqualizer(settings)
                            }
                        ))
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
                        if library.serverID.isEmpty {
                            Text("Choose a Plex server to cache artwork.").foregroundStyle(.secondary)
                        } else {
                            Text("Save album covers, artist pictures, and movie and TV show posters from the selected libraries to this device.")
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
            if !library.connected {
                if library.busy {
                    #if os(tvOS)
                    if let code = library.linkCode {
                        Text("On your phone or computer, go to plex.tv/link and enter this code.")
                        Text(code).font(.title.monospaced())
                    } else {
                        ProgressView("Connecting…")
                    }
                    #else
                    ProgressView("Connecting…")
                    if let url = library.signInURL { Link("Reopen Plex sign-in", destination: url) }
                    #endif
                    Button("Cancel", action: library.cancel)
                } else {
                    Button("Connect Plex", action: library.signIn)
                }
            } else if library.servers.isEmpty {
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
                Picker("Tool Drive Library", selection: Binding(get: { library.toolDriveLibraryID }, set: library.chooseToolDriveLibrary)) {
                    Text("Choose library").tag("")
                    ForEach(library.libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            if library.libraryID.isEmpty, let message = library.message {
                Text(message).foregroundStyle(.secondary)
            }
            if library.connected { Button("Disconnect Plex", action: library.disconnect) }
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


struct GlassColorControl: View {
    let title: String
    @Binding var saved: String
    let defaultHex: String
    @State private var input = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { picker; Spacer(minLength: 8); controls }
                VStack(alignment: .leading, spacing: 8) { picker; controls }
            }
            if invalid { Text("Enter a six-digit hex color, such as " + defaultHex + ".").font(.caption) }
        }
        .font(.callout)
        .onChange(of: saved, initial: true) { _, value in input = value; invalid = false }
    }

    @ViewBuilder private var picker: some View {
        let color = LiquidGlassColor.color(saved) ?? LiquidGlassColor.color(defaultHex) ?? .white
        #if os(tvOS)
        HStack {
            Text(title)
            Circle().fill(color).frame(width: 24, height: 24).accessibilityHidden(true)
        }
        #else
        ColorPicker(title, selection: Binding(get: { color }, set: {
            if let hex = LiquidGlassColor.hex($0) { saved = hex }
        }), supportsOpacity: false)
        #endif
    }

    private var controls: some View {
        HStack {
            TextField(defaultHex, text: $input)
                .accessibilityLabel(title + " hex value")
                .font(.body.monospaced())
                #if !os(tvOS)
                .frame(width: 92)
                #endif
                .onSubmit(apply)
            Button("Apply", action: apply)
                .accessibilityLabel("Apply " + title)
                .disabled(input.isEmpty)
            Button("Reset") { saved = ""; input = ""; invalid = false }
                .accessibilityLabel("Reset " + title)
                .disabled(saved.isEmpty && input.isEmpty)
        }
    }

    private func apply() {
        guard let hex = LiquidGlassColor.hex(input) else { invalid = true; return }
        saved = hex
        input = hex
        invalid = false
    }
}
