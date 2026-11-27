import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
typealias MusicImage = NSImage
#else
import UIKit
typealias MusicImage = UIImage
#endif

@MainActor
enum MusicPlatform {
    private static let wordmarkSheet: CGImage? = {
        guard let url = Bundle.main.url(forResource: "music-wordmarks", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    private static let wordmarks = loadWordmarks(dark: false)
    private static let darkWordmarks = loadWordmarks(dark: true)

    private static func loadWordmarks(dark: Bool) -> [HeaderWordmark: CGImage] {
        Dictionary(uniqueKeysWithValues: HeaderWordmark.allCases.compactMap { option in
            guard let region = option.region(dark: dark), let crop = wordmarkSheet?.cropping(to: region) else { return nil }
            return (option, crop)
        })
    }

    private static let spotifyHeader: (logo: CGImage?, wordmark: CGImage?) = {
        guard let url = Bundle.main.url(forResource: "spotify-brand", withExtension: "png", subdirectory: "HeaderMarks"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (nil, nil) }
        return (image.cropping(to: CGRect(x: 48, y: 13, width: 915, height: 915)),
                image.cropping(to: CGRect(x: 1149, y: 212, width: 2235, height: 596)))
    }()

    static func headerLogoImage(_ option: HeaderMark) -> Image? {
        if option == .spotify {
            return spotifyHeader.logo.map { Image(decorative: $0, scale: 1) }
        }
        return brandImage(option.assetName, subdirectory: "HeaderMarks")
    }

    static func wordmarkImage(_ option: HeaderWordmark, dark: Bool) -> Image? {
        if option == .iplex { return brandImage("wordmark") }
        if option == .spotify { return spotifyHeader.wordmark.map { Image(decorative: $0, scale: 1) } }
        if let assetName = option.assetName { return brandImage(assetName, subdirectory: "HeaderMarks") }
        return (dark ? darkWordmarks : wordmarks)[option].map { Image(decorative: $0, scale: 1) }
    }

    static func brandImage(_ name: String, subdirectory: String? = nil) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdirectory) else {
            return nil
        }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }

    static func image(_ image: CGImage) -> MusicImage {
        #if os(macOS)
        NSImage(cgImage: image, size: .zero)
        #else
        UIImage(cgImage: image)
        #endif
    }

    #if !os(tvOS)
    static func openSignIn(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    #endif
}

struct ArtworkPalette {
    static let preferenceKey = "UseArtworkColors"

    private struct Sample {
        var weight = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
    }

    private let rgb: SIMD3<Double>

    @MainActor init?(_ artwork: MusicImage) {
        #if os(macOS)
        guard let image = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let image = artwork.cgImage else { return nil }
        #endif
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var bins = [Sample](repeating: Sample(), count: 64)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3])
            guard alpha >= 128 else { continue }
            let red = min(1, Double(pixels[index]) / alpha)
            let green = min(1, Double(pixels[index + 1]) / alpha)
            let blue = min(1, Double(pixels[index + 2]) / alpha)
            let high = max(red, green, blue)
            let chroma = high - min(red, green, blue)
            let weight = (0.08 + chroma * 3) * (0.3 + high)
            let index = Int(red * 3.999) * 16 + Int(green * 3.999) * 4 + Int(blue * 3.999)
            bins[index].weight += weight
            bins[index].red += red * weight
            bins[index].green += green * weight
            bins[index].blue += blue * weight
        }
        guard let best = bins.max(by: { $0.weight < $1.weight }), best.weight > 0 else { return nil }
        rgb = SIMD3(best.red, best.green, best.blue) / best.weight
    }

    func accent(in scheme: ColorScheme) -> Color {
        scheme == .dark ? color(mixing: 1, amount: 0.55) : color(mixing: 0, amount: 0.55)
    }

    func wash(in scheme: ColorScheme) -> Color {
        scheme == .dark ? color(mixing: 0.08, amount: 0.67) : color(mixing: 1, amount: 0.72)
    }

    private func color(mixing neutral: Double, amount: Double) -> Color {
        let result = rgb * (1 - amount) + SIMD3(repeating: neutral * amount)
        return Color(red: result.x, green: result.y, blue: result.z)
    }
}

enum VideoHeaderBrand: String {
    case comcast2000 = "comcast-2000"
    case attUverse2016 = "att-uverse-2016"
    case att2016 = "att-2016"
    case xfinity
    case dishNetwork = "dish-network"
    case directv
    case directvClassic = "directv-classic"

    var label: String {
        switch self {
        case .comcast2000: "Comcast (2000)"
        case .attUverse2016: "AT&T U-verse (2016)"
        case .att2016: "AT&T (2016)"
        case .xfinity: "Xfinity"
        case .dishNetwork: "DISH Network"
        case .directv: "DIRECTV"
        case .directvClassic: "DIRECTV (Classic)"
        }
    }
}

enum HeaderWordmark: String, CaseIterable, Identifiable {
    static let preferenceKey = "HeaderWordmark"
    case iplex, music, musicBold, plex, plex2022, napster, spotify, netflix, iTunes
    case hulu
    case disneyPlus = "disney-plus"
    case disneyPlusMono = "disney-plus-mono"
    case appleTV = "apple-tv"
    case appleTVClassic = "apple-tv-classic"
    case appleTVGlass = "apple-tv-glass"
    case toolDriveProject = "tool-drive-project"
    case realJukebox, realJukeboxPlus, realPlayer, realPlayerBasic, realPlayerPlus
    case comcast2000 = "comcast-2000"
    case attUverse2016 = "att-uverse-2016"
    case att2016 = "att-2016"
    case xfinity
    case dishNetwork = "dish-network"
    case directv
    case directvClassic = "directv-classic"

    case toolArchiveClassic = "tool-archive-classic"
    case toolArchive2006 = "tool-archive-2006"
    case toolArchiveOpiate = "tool-archive-opiate"
    case toolArchiveOpiate2 = "tool-archive-opiate2"
    case toolArchiveFearInoculum = "tool-archive-fear-inoculum"
    case toolArchiveMulticolor = "tool-archive-multicolor"
    case toolArchiveMarbled = "tool-archive-marbled"
    case toolArchiveSpectrum = "tool-archive-spectrum"
    case toolArchiveBlock = "tool-archive-block"
    case toolArchiveReflection = "tool-archive-reflection"
    case toolArchiveFramed = "tool-archive-framed"
    case toolArchiveOrbit = "tool-archive-orbit"
    case toolArchiveStatic = "tool-archive-static"
    case toolArchiveErosion = "tool-archive-erosion"
    case toolArchiveAfterimage = "tool-archive-afterimage"
    case toolArchiveLightTrail = "tool-archive-light-trail"
    case toolArchiveFlare = "tool-archive-flare"
    case toolArchiveBlueMist = "tool-archive-blue-mist"
    case toolArchive1992 = "tool-archive-1992"
    case toolArchiveAenima = "tool-archive-aenima"
    case toolArchiveBone = "tool-archive-bone"
    case none

    var videoBrand: VideoHeaderBrand? { VideoHeaderBrand(rawValue: rawValue) }

    var isToolArchive: Bool { rawValue.hasPrefix("tool-archive-") }

    static func choices(for section: HeaderBrandSection) -> [Self] {
        allCases.filter {
            if $0.isToolArchive { return section == .toolDrive }
            return section.supportsVideoBranding || $0.videoBrand == nil
        }
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .iplex: "iPlex"
        case .music, .musicBold: "Music"
        case .plex, .plex2022: "Plex"
        case .napster: "Napster"
        case .spotify: "Spotify"
        case .netflix: "Netflix"
        case .hulu: "Hulu"
        case .disneyPlus: "Disney+"
        case .disneyPlusMono: "Disney+ (Monochrome)"
        case .appleTV: "Apple TV"
        case .appleTVClassic: "Apple TV (Classic)"
        case .appleTVGlass: "Apple TV (Glass)"
        case .toolDriveProject: "Tool Drive Project"
        case .iTunes: "iTunes"
        case .realJukebox: "RealJukebox"
        case .realJukeboxPlus: "RealJukebox Plus"
        case .realPlayer: "RealPlayer"
        case .realPlayerBasic: "RealPlayer Basic"
        case .realPlayerPlus: "RealPlayer Plus"
        case .comcast2000, .attUverse2016, .att2016, .xfinity,
             .dishNetwork, .directv, .directvClassic: videoBrand?.label ?? rawValue
        case .toolArchiveClassic: "Tool Classic"
        case .toolArchive2006: "Tool 2006"
        case .toolArchiveOpiate: "Tool Opiate"
        case .toolArchiveOpiate2: "Tool Opiate²"
        case .toolArchiveFearInoculum: "Tool Fear Inoculum"
        case .toolArchiveMulticolor: "Tool Multicolor"
        case .toolArchiveMarbled: "Tool Marbled"
        case .toolArchiveSpectrum: "Tool Spectrum"
        case .toolArchiveBlock: "Tool Block"
        case .toolArchiveReflection: "Tool Reflection"
        case .toolArchiveFramed: "Tool Framed"
        case .toolArchiveOrbit: "Tool Orbit"
        case .toolArchiveStatic: "Tool Static"
        case .toolArchiveErosion: "Tool Erosion"
        case .toolArchiveAfterimage: "Tool Afterimage"
        case .toolArchiveLightTrail: "Tool Light Trail"
        case .toolArchiveFlare: "Tool Flare"
        case .toolArchiveBlueMist: "Tool Blue Mist"
        case .toolArchive1992: "Tool 1992"
        case .toolArchiveAenima: "Tool Ænima"
        case .toolArchiveBone: "Tool Bone"
        case .none: "None"
        }
    }
    var label: String {
        switch self {
        case .musicBold: "music (Bold)"
        case .plex: "Plex (Classic)"
        case .plex2022: "Plex (2022)"
        default: title
        }
    }
    var assetName: String? {
        switch self {
        case .netflix: "netflix-wordmark"
        case .toolDriveProject: "tool-drive-project-wordmark"
        case .hulu, .disneyPlus, .disneyPlusMono, .appleTV, .appleTVClassic, .appleTVGlass: rawValue
        default: videoBrand != nil || isToolArchive ? rawValue : nil
        }
    }

    var preservesColors: Bool {
        switch self {
        case .spotify, .netflix, .hulu, .disneyPlus, .appleTVGlass: true
        case .toolArchiveClassic, .toolArchive2006: false
        default: isToolArchive || videoBrand != nil || region(dark: false) != region(dark: true)
        }
    }

    // Pixel coordinates shared with the Windows asset sheet.
    func region(dark: Bool) -> CGRect? {
        switch self {
        case .music: CGRect(x: 722, y: 251, width: 684, height: 210)
        case .musicBold: CGRect(x: 645, y: 609, width: 810, height: 193)
        case .plex: CGRect(x: 0, y: dark ? 1745 : 1255, width: 1024, height: 332)
        case .plex2022: CGRect(x: 1030, y: dark ? 1745 : 1255, width: 1000, height: 461)
        case .napster: CGRect(x: 0, y: 1085, width: 707, height: 156)
        case .iTunes: CGRect(x: 720, y: 1085, width: 565, height: 144)
        case .realJukebox: CGRect(x: 0, y: dark ? 2508 : 2206, width: 1000, height: 248)
        case .realJukeboxPlus: CGRect(x: 1020, y: dark ? 2508 : 2206, width: 1000, height: 300)
        case .realPlayer: CGRect(x: 0, y: dark ? 2988 : 2808, width: 471, height: 146)
        case .realPlayerBasic: CGRect(x: 520, y: dark ? 2988 : 2808, width: 482, height: 175)
        case .realPlayerPlus: CGRect(x: 1040, y: dark ? 2988 : 2808, width: 471, height: 176)
        default: nil
        }
    }
}

enum HeaderMark: String, CaseIterable, Identifiable {
    static let preferenceKey = "HeaderMark"
    case none, black, white, rainbow, gold, aurora, silver, napster, spotify, netflix, hulu
    case disneyPlus = "disney-plus"
    case disneyPlusMono = "disney-plus-mono"
    case appleTV = "apple-tv"
    case appleTVClassic = "apple-tv-classic"
    case appleTVGlass = "apple-tv-glass"
    case toolDriveProject = "tool-drive-project"
    case plexChevron = "plex-chevron"
    case realPlayer = "realplayer"
    case realPlayerGartoon = "realplayer-gartoon"

    case wmpClassic = "wmp-classic"
    case mediaPlayerClassic = "media-player-classic"
    case wmpGlass = "wmp-glass"
    case vlcClassic = "vlc-classic"
    case vlc
    case quicktime
    case itunesDisc = "itunes-disc"
    case itunes11 = "itunes-11"

    case comcast2000 = "comcast-2000"
    case attUverse2016 = "att-uverse-2016"
    case att2016 = "att-2016"
    case xfinity
    case dishNetwork = "dish-network"
    case directv
    case directvClassic = "directv-classic"

    case toolArchiveSawblade = "tool-archive-sawblade"

    var id: Self { self }
    var isMonochrome: Bool { self == .black || self == .white }
    var usesTextColor: Bool {
        self == .disneyPlusMono || self == .appleTV || self == .appleTVClassic
    }

    var videoBrand: VideoHeaderBrand? { VideoHeaderBrand(rawValue: rawValue) }

    static func choices(for section: HeaderBrandSection) -> [Self] {
        allCases.filter {
            if $0.videoBrand != nil { return section.supportsVideoBranding }
            if $0 == .toolArchiveSawblade { return section == .toolDrive }
            return $0 != .toolDriveProject || section != .toolDrive
        }
    }
    var assetName: String { isMonochrome ? "monochrome" : rawValue }
    // Ratios of the canvas height to the visible artwork height.
    var artworkScale: CGFloat {
        switch self {
        case .aurora: 400.0 / 390.0
        case .gold: 622.0 / 621.0
        case .rainbow: 1118.0 / 1117.0
        case .silver: 409.0 / 315.0
        default: 1
        }
    }
    var label: String {
        switch self {
        case .toolArchiveSawblade: "Tool Sawblade"
        case .comcast2000, .attUverse2016, .att2016, .xfinity,
             .dishNetwork, .directv, .directvClassic: videoBrand?.label ?? rawValue
        case .none: "Text Only"
        case .black: "Black"
        case .white: "White"
        case .rainbow: "Rainbow"
        case .gold: "Brushed Gold"
        case .aurora: "Aurora"
        case .silver: "Polished Silver"
        case .napster: "Napster"
        case .wmpClassic: "Windows Media Player 4"
        case .mediaPlayerClassic: "Media Player Classic"
        case .wmpGlass: "Windows Media Player Glass"
        case .vlcClassic: "VLC Classic"
        case .vlc: "VLC"
        case .quicktime: "QuickTime"
        case .itunesDisc: "iTunes Disc"
        case .itunes11: "iTunes 11"
        case .spotify: "Spotify"
        case .netflix: "Netflix"
        case .hulu: "Hulu"
        case .disneyPlus: "Disney+"
        case .disneyPlusMono: "Disney+ (Monochrome)"
        case .appleTV: "Apple TV"
        case .appleTVClassic: "Apple TV (Classic)"
        case .appleTVGlass: "Apple TV (Glass)"
        case .toolDriveProject: "Tool Drive Project"
        case .plexChevron: "Plex Chevron"
        case .realPlayer: "RealPlayer"
        case .realPlayerGartoon: "RealPlayer Gartoon"
        }
    }
}

enum HeaderMarkSize: String, CaseIterable, Identifiable {
    static let preferenceKey = "HeaderMarkSize"
    case small, medium, large, extraLarge

    var id: Self { self }
    var label: String { self == .extraLarge ? "XL" : rawValue.capitalized }
    var fraction: CGFloat {
        switch self {
        case .small: 0.48
        case .medium: 0.68
        case .large: 0.82
        case .extraLarge: 0.94
        }
    }
}

enum HeaderBrandSection: String, CaseIterable, Identifiable {
    case movies, television, toolDrive, music, downloads

    init(video: PlexVideoKind?) {
        switch video {
        case nil: self = .music
        case .movies: self = .movies
        case .television: self = .television
        }
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .music: "Music"
        case .toolDrive: "Tool Drive"
        case .downloads: "Downloads"
        case .movies: PlexVideoKind.movies.title
        case .television: PlexVideoKind.television.title
        }
    }

    var supportsVideoBranding: Bool { self == .movies || self == .television }

    func preferenceKey(_ base: String) -> String {
        self == .music ? base : "\(base).\(rawValue)"
    }
}

struct HeaderBrandChoices: DynamicProperty {
    @AppStorage private var mark: HeaderMark
    @AppStorage private var wordmark: HeaderWordmark

    init(section: HeaderBrandSection) {
        _mark = AppStorage(wrappedValue: .none, section.preferenceKey(HeaderMark.preferenceKey))
        _wordmark = AppStorage(wrappedValue: section == .toolDrive ? .toolArchiveClassic : .iplex,
                               section.preferenceKey(HeaderWordmark.preferenceKey))
    }

    static func migrateToolDriveLogo(in defaults: UserDefaults) {
        let section = HeaderBrandSection.toolDrive
        let logoKey = section.preferenceKey(HeaderMark.preferenceKey)
        let wordmarkKey = section.preferenceKey(HeaderWordmark.preferenceKey)
        guard let saved = defaults.string(forKey: logoKey),
              let wordmark = HeaderWordmark(rawValue: saved),
              wordmark.isToolArchive || wordmark == .toolDriveProject else { return }
        defaults.set(wordmark.rawValue, forKey: wordmarkKey)
        defaults.set(HeaderMark.none.rawValue, forKey: logoKey)
    }

    var logoSelection: Binding<HeaderMark> { $mark }
    var wordmarkSelection: Binding<HeaderWordmark> { $wordmark }
}

struct HeaderBrand: View {
    @AppStorage(HeaderMarkSize.preferenceKey) private var markSize = HeaderMarkSize.medium
    let theme: MusicTheme
    let width: CGFloat
    let height: CGFloat
    var allowsCycling = true
    let section: HeaderBrandSection
    @Binding var mark: HeaderMark
    @Binding var wordmark: HeaderWordmark

    private var ink: Color { theme.text }
    private var markHeight: CGFloat { height * markSize.fraction }
    private var markOutline: Color {
        if mark == .black { return .white.opacity(0.7) }
        if mark.videoBrand != nil { return .white.opacity(0.45) }
        return .clear
    }
    private var markWidth: CGFloat {
        mark.videoBrand == nil ? markHeight : min(width * 0.48, markHeight * 2.25)
    }
    private var markColor: Color {
        if mark.usesTextColor { return ink }
        return mark == .black ? .black : .white
    }

    var body: some View {
        HStack(spacing: 8) {
            if mark != .none, let image = MusicPlatform.headerLogoImage(mark) {
                cycleControl(label: "Change header logo", selection: mark.label, advance: cycleMark) {
                    image.renderingMode(mark.isMonochrome || mark.usesTextColor ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(markColor)
                        .shadow(color: markOutline, radius: 1)
                        .frame(width: markWidth, height: markHeight)
                        .scaleEffect(mark.artworkScale)
                }
            }
            if wordmark != .none {
                cycleControl(label: "Change header wordmark", selection: wordmark.label, advance: cycleWordmark) {
                    if let image = MusicPlatform.wordmarkImage(wordmark, dark: true) {
                        image.renderingMode(wordmark.preservesColors ? .original : .template).resizable().scaledToFit()
                            .foregroundStyle(ink)
                            .shadow(color: wordmark.videoBrand == nil ? .clear : .white.opacity(0.45), radius: 1)
                    } else {
                        Text(wordmark.title).font(.system(size: height * 0.68, weight: wordmark == .musicBold ? .bold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    @ViewBuilder private func cycleControl<Content: View>(label: String, selection: String, advance: @escaping () -> Void,
                                                          @ViewBuilder content: () -> Content) -> some View {
        if allowsCycling {
            Button(action: advance) { content().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(selection)
        } else {
            content()
        }
    }

    private func cycleMark() {
        let choices = HeaderMark.choices(for: section).filter { $0 != .none }
        let current = choices.firstIndex(of: mark) ?? -1
        mark = choices[(current + 1) % choices.count]
    }

    private func cycleWordmark() {
        let choices = HeaderWordmark.choices(for: section).filter { $0 != .none }
        let current = choices.firstIndex(of: wordmark) ?? -1
        wordmark = choices[(current + 1) % choices.count]
    }
}

struct SectionHeaderBrand: View {
    let section: HeaderBrandSection
    let theme: MusicTheme
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        SectionBrandContent(section: section, theme: theme, width: width, height: height)
            .id(section)
    }

    private struct SectionBrandContent: View {
        let theme: MusicTheme
        let width: CGFloat
        let height: CGFloat
        private let section: HeaderBrandSection
        private var choices: HeaderBrandChoices

        init(section: HeaderBrandSection, theme: MusicTheme, width: CGFloat, height: CGFloat) {
            self.section = section
            self.theme = theme
            self.width = width
            self.height = height
            choices = HeaderBrandChoices(section: section)
        }

        var body: some View {
            HeaderBrand(theme: theme, width: width, height: height, section: section,
                        mark: choices.logoSelection, wordmark: choices.wordmarkSelection)
        }
    }
}

struct PlexLibrarySwitcher: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        if !library.libraries.isEmpty {
            Picker("Music Library", selection: Binding(get: { library.libraryID }, set: library.chooseLibrary)) {
                if library.libraryID.isEmpty { Text("Choose Library").tag("") }
                ForEach(library.libraries, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityLabel("Switch Music Library")
            .disabled(library.reconnecting)
        }
    }
}

extension ScrollView {
    func libraryScrollTopInset() -> some View {
        contentMargins(.top, 8, for: .scrollContent)
    }
}

struct LibraryBrowseControls<Selector: View>: View {
    let placeholder: String
    let query: Binding<String>?
    let searchDisabled: Bool
    @ViewBuilder let selector: () -> Selector
    @MusicAppearance private var appearance

    var body: some View {
        Group {
            #if os(tvOS)
            HStack(spacing: 18) {
                if let query {
                    TextField(placeholder, text: query)
                        .disabled(searchDisabled)
                        .accessibilityIdentifier("tv.library.search")
                }
                selector()
            }
            .focusSection()
            #elseif os(iOS)
            row(searchWidth: nil)
            #else
            ViewThatFits(in: .horizontal) {
                row(searchWidth: 205).fixedSize(horizontal: true, vertical: false)
                row(searchWidth: nil)
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func row(searchWidth: CGFloat?) -> some View {
        HStack(spacing: 12) {
            selector().glassHover()
                #if os(iOS)
                .frame(width: 120)
                #else
                .frame(width: 160)
                #endif
            if let query {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(placeholder, text: query)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .submitLabel(.search)
                        #endif
                }
                .padding(9)
                .musicGlass(appearance, radius: 12)
                .glassHover(radius: 12)
                .disabled(searchDisabled)
                .frame(width: searchWidth)
            }
        }
    }
}

#if os(macOS)
struct LibraryBrowseHeader<Heading: View, Controls: View>: View {
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 15) {
                heading()
                controls().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading()
                controls()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.vertical, 20)
    }
}
#endif

struct PlexArtwork<Placeholder: View>: View {
    let item: MusicEntry
    let library: LibraryModel
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (key: LibraryModel.ArtworkKey, image: MusicImage)?

    var body: some View {
        let key = library.artworkKey(for: item)
        Group {
            if let loaded, loaded.key == key {
                #if os(macOS)
                Image(nsImage: loaded.image).resizable().scaledToFill()
                #else
                Image(uiImage: loaded.image).resizable().scaledToFill()
                #endif
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard let key, loaded?.key != key else { return }
            loaded = nil
            guard let image = await library.image(for: key), !Task.isCancelled else { return }
            loaded = (key, image)
        }
        .onDisappear { loaded = nil }
    }
}

struct LibraryAlternateLayout: View {
    @ObservedObject var library: LibraryModel
    let layout: LibraryLayout

    private var listsTracks: Bool { library.kind == .tracks && library.selectedGroup == nil }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: layout == .albumTracks ? 16 : 2) {
            if layout == .trackList && listsTracks {
                LibraryTrackColumns(number: "#", title: "Track", artist: "Artist", album: "Album", duration: "Time", headings: true)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(library.entries.enumerated()), id: \.element.id) { index, entry in
                if layout == .albumTracks {
                    LibraryAlbumWithTracks(library: library, entry: entry)
                } else {
                    Button {
                        if entry.kind == .tracks { library.playLibraryTrack(entry) }
                        else { library.open(entry) }
                    } label: {
                        if entry.kind == .tracks {
                            let details = entry.trackDetails
                            let number = details?.number.map { index in
                                if let disc = details?.disc, disc > 1 { return "\(disc).\(index)" }
                                return String(index)
                            }
                            LibraryTrackColumns(
                                number: number ?? "–", title: entry.title, artist: entry.artist,
                                album: details?.album ?? "", duration: LibraryTrackColumns.clock(details?.duration)
                            )
                        } else {
                            HStack {
                                Text(entry.title).fontWeight(.medium)
                                Spacer()
                                Text(entry.artist).foregroundStyle(.secondary)
                            }.lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.045) : Color.clear, in: .rect(cornerRadius: 5))
                    .glassHover(radius: 6)
                    .disabled(library.reconnecting)
                    .contextMenu {
                        if !entry.kind.isGroup { LibraryQueueActions(library: library, entry: entry) }
                        PlexPinButton(library: library, entry: entry)
                    }
                }
            }
            if library.more && !library.busy && library.message == nil {
                Color.clear.frame(height: 1).accessibilityHidden(true)
                    .id(library.entries.count)
                    .onAppear { library.loadMore() }
            }
        }
    }
}

private struct LibraryAlbumWithTracks: View {
    @ObservedObject var library: LibraryModel
    let entry: MusicEntry
    @MusicAppearance private var theme
    @AppStorage(LibraryArtworkSize.preferenceKey) private var artworkSize = LibraryArtworkSize.medium
    @State private var tracks: [LiveTrack] = []
    @State private var failed = false
    @State private var attempt = 0
    private var previewKey: String { [library.serverID, library.libraryID, entry.id, String(library.reconnecting), String(attempt)].joined(separator: ":") }

    var body: some View {
        Group {
            #if os(iOS)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    albumCover
                    trackRows.frame(minWidth: 230)
                }
                VStack(alignment: .leading, spacing: 12) {
                    albumCover
                    trackRows
                }
            }
            #else
            HStack(alignment: .top, spacing: 18) {
                albumCover
                trackRows
            }
            #endif
        }
        .modifier(LibraryAlbumCard(theme: theme))
        .task(id: previewKey) { await load() }
    }

    private var albumCover: some View {
        let width = (118 * artworkSize.scale).rounded()
        return Button { library.open(entry) } label: {
            VStack(alignment: .leading, spacing: 5) {
                PlexArtwork(item: entry, library: library) {
                    Image(systemName: "opticaldisc").font(.title2).foregroundStyle(.secondary)
                }
                .frame(width: width, height: width)
                .background(.primary.opacity(0.08))
                .clipShape(.rect(cornerRadius: 9))
                Text(entry.title).font(.headline)
                Text(entry.artist).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(2)
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(library.reconnecting)
        .contextMenu {
            LibraryQueueActions(library: library, entry: entry)
            PlexPinButton(library: library, entry: entry)
        }
    }

    private var trackRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            if library.reconnecting {
                Text("Reconnecting to Plex…").foregroundStyle(.secondary)
            } else if failed {
                Button("Retry Tracks", systemImage: "arrow.clockwise") { attempt += 1 }
            } else if tracks.isEmpty {
                ProgressView("Loading tracks…")
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button { library.play(entry, albumTracks: tracks, at: index) } label: {
                        LibraryTrackColumns(number: String(track.number), title: track.title, artist: track.artist ?? entry.artist,
                                            album: nil, duration: LibraryTrackColumns.clock(track.duration))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.045) : Color.clear, in: .rect(cornerRadius: 5))
                    .contextMenu { LibraryQueueActions(library: library, entry: entry, track: track) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        guard !library.reconnecting else { return }
        failed = false
        do { tracks = try await library.previewAlbumTracks(entry) }
        catch {
            if !Task.isCancelled && !(error is CancellationError) { failed = true }
        }
    }
}

private struct LibraryAlbumCard: ViewModifier {
    let theme: MusicTheme

    func body(content: Content) -> some View {
        content.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
            .musicGlass(theme, radius: 12)
    }
}

private struct LibraryTrackColumns: View {
    let number: String
    let title: String
    let artist: String
    let album: String?
    let duration: String
    var headings = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        HStack(spacing: 9) {
            Text(number).monospacedDigit().frame(width: 35, alignment: .trailing)
            #if os(iOS)
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    if !headings && !artist.isEmpty {
                        Text([artist, album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                textColumns
            }
            #else
            textColumns
            #endif
            Text(duration).monospacedDigit().frame(width: 49, alignment: .trailing)
        }
        .lineLimit(1)
        .font(headings ? .caption.weight(.semibold) : .callout)
        .foregroundStyle(headings ? .secondary : .primary)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var textColumns: some View {
        Text(title).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
        Text(artist).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        if let album { Text(album).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
    }

    static func clock(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0, duration < Double(Int32.max) else { return "–" }
        let seconds = Int(duration.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
