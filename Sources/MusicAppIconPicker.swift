import SwiftUI

enum AppIconChoice: String, CaseIterable, Identifiable {
    case groove, prism, signal, clickwheel
    case prismaticLight = "prismatic-note"
    case prismaticDark = "prismatic-note-dark"
    case musicGradient = "music-gradient"
    case musicWordmark = "music-wordmark"
    case musicCrimson = "music-crimson"
    case musicMonochrome = "music-monochrome"
    case musicOrange = "music-orange"
    case musicArtists = "music-artists"
    case musicPink = "music-pink"
    case napster, napsterMono = "napster-mono", spotify, plex

    var id: String { rawValue }

    var alternateName: String? {
        if self == .groove { return nil }
        if self == .clickwheel { return "ClassicClickWheel" }
        return rawValue.split(separator: "-").map { $0.capitalized }.joined()
    }

    var label: String {
        switch self {
        case .groove: "Copper Groove"
        case .prism: "Prism"
        case .signal: "Teal Signal"
        case .clickwheel: "Classic Click Wheel"
        case .prismaticLight: "Prismatic Note Light"
        case .prismaticDark: "Prismatic Note Dark"
        case .musicGradient: "Gradient Note"
        case .musicWordmark: "Music Wordmark"
        case .musicCrimson: "Crimson Note"
        case .musicMonochrome: "Monochrome Note"
        case .musicOrange: "Retro Orange"
        case .musicArtists: "Artists Gradient"
        case .musicPink: "Pink Note"
        case .napster: "Napster"
        case .napsterMono: "Napster Monochrome"
        case .spotify: "Spotify"
        case .plex: "Plex"
        }
    }
}

#if os(iOS) || os(tvOS)
import UIKit

struct MusicAppIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var changingIcon = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("App Icon").font(.title.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 15)], spacing: 15) {
                    ForEach(AppIconChoice.allCases) { option($0) }
                }
                .padding(12)
            }
            .frame(maxWidth: 1200, maxHeight: 590)
            .disabled(changingIcon || !UIApplication.shared.supportsAlternateIcons)
            if let message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !UIApplication.shared.supportsAlternateIcons {
                Text("Alternate icons are unavailable on this device.").foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .disabled(changingIcon)
        }
        .padding(24)
    }

    private var tileWidth: CGFloat {
        #if os(tvOS)
        195
        #else
        104
        #endif
    }

    private func option(_ choice: AppIconChoice) -> some View {
        let icon = choice.alternateName
        let selected = icon == currentIcon
        return Button {
            guard !selected else { return }
            changingIcon = true
            message = nil
            Task {
                defer { changingIcon = false }
                do {
                    try await UIApplication.shared.setAlternateIconName(icon)
                    currentIcon = icon
                } catch {
                    message = "The app icon couldn’t be changed. Try again."
                }
            }
        } label: {
            VStack(spacing: 10) {
                #if os(tvOS)
                let folder = "TVIconPreviews"
                let previewSize = CGSize(width: 164, height: 98)
                #else
                let folder = "iOSIconPreviews"
                let previewSize = CGSize(width: 75, height: 75)
                #endif
                if let url = Bundle.main.url(forResource: choice.rawValue, withExtension: "png", subdirectory: folder),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                }
                Text(choice.label).multilineTextAlignment(.center)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
