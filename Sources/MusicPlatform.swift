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
