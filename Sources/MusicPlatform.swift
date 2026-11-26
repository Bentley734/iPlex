import CoreGraphics
import Foundation
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
            if let wordmark = MusicPlatform.brandImage("wordmark") {
                wordmark.resizable().scaledToFit()
                    .colorMultiply(ink)
                    .accessibilityLabel("iPlex")
            } else {
                Text("iPlex").font(.system(size: height * 0.68, weight: .medium))
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
