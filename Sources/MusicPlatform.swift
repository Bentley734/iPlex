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

    static func wordmarkImage(_ option: HeaderWordmark, dark: Bool) -> Image? {
        if option == .iplex { return brandImage("wordmark") }
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

enum HeaderWordmark: String, CaseIterable, Identifiable {
    static let preferenceKey = "HeaderWordmark"
    case iplex, music, musicBold, plex, plex2022, napster, iTunes

    var id: Self { self }
    var title: String {
        switch self {
        case .iplex: "iPlex"
        case .music, .musicBold: "Music"
        case .plex, .plex2022: "Plex"
        case .napster: "Napster"
        case .iTunes: "iTunes"
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
    var hasAccent: Bool { self == .plex || self == .plex2022 }

    // Pixel coordinates shared with the Windows asset sheet.
    func region(dark: Bool) -> CGRect? {
        switch self {
        case .iplex: nil
        case .music: CGRect(x: 722, y: 251, width: 684, height: 210)
        case .musicBold: CGRect(x: 645, y: 609, width: 810, height: 193)
        case .plex: CGRect(x: 0, y: dark ? 1745 : 1255, width: 1024, height: 332)
        case .plex2022: CGRect(x: 1030, y: dark ? 1745 : 1255, width: 1000, height: 461)
        case .napster: CGRect(x: 0, y: 1085, width: 707, height: 156)
        case .iTunes: CGRect(x: 720, y: 1085, width: 565, height: 144)
        }
    }
}

enum HeaderMark: String, CaseIterable, Identifiable {
    static let preferenceKey = "HeaderMark"
    case none, black, white, rainbow, gold, aurora, silver

    var id: Self { self }
    var isMonochrome: Bool { self == .black || self == .white }
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
        case .none: "Text Only"
        case .black: "Black"
        case .white: "White"
        case .rainbow: "Rainbow"
        case .gold: "Brushed Gold"
        case .aurora: "Aurora"
        case .silver: "Polished Silver"
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

struct HeaderBrand: View {
    @AppStorage(HeaderMarkSize.preferenceKey) private var markSize = HeaderMarkSize.medium
    @AppStorage(HeaderWordmark.preferenceKey) private var wordmark = HeaderWordmark.iplex
    let mark: HeaderMark
    let theme: MusicTheme
    let width: CGFloat
    let height: CGFloat

    private var ink: Color { theme.scheme == .light ? .black : .white }
    private var markHeight: CGFloat { height * markSize.fraction }
    private var markOutline: Color {
        if mark == .black && theme.scheme == .dark { return .white.opacity(0.7) }
        if mark == .white && theme.scheme == .light { return .black.opacity(0.6) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            if mark != .none, let image = MusicPlatform.brandImage(mark.assetName, subdirectory: "HeaderMarks") {
                image.renderingMode(mark.isMonochrome ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(mark == .black ? .black : .white)
                    .shadow(color: markOutline, radius: 1)
                    .frame(width: markHeight, height: markHeight)
                    .scaleEffect(mark.artworkScale)
                    .accessibilityHidden(true)
            }
            if let image = MusicPlatform.wordmarkImage(wordmark, dark: theme.scheme == .dark) {
                image.renderingMode(wordmark.hasAccent ? .original : .template).resizable().scaledToFit()
                    .foregroundStyle(ink)
                    .accessibilityLabel(wordmark.title)
            } else {
                Text(wordmark.title).font(.system(size: height * 0.68, weight: wordmark == .musicBold ? .bold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }
}

struct PlexifyFeature: View {
    let item: MusicEntry
    let library: LibraryModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 18) {
                Color.white.opacity(0.10).overlay {
                    PlexArtwork(item: item, library: library) {
                        Image(systemName: item.kind == .albums ? "opticaldisc" : "person.crop.circle")
                            .font(.title).foregroundStyle(MusicTheme.plexify.accent)
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text("From your library")
                        .font(.caption.weight(.semibold)).foregroundStyle(MusicTheme.plexify.accent)
                    Text(item.title).font(.title2.weight(.bold)).lineLimit(2)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
                    .foregroundStyle(MusicTheme.plexify.accent)
            }
            .padding(16)
            .background {
                LinearGradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.30), MusicTheme.plexify.surface],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
            }
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)) }
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

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
