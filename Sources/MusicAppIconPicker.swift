import SwiftUI

enum AppIconChoice: String, CaseIterable, Identifiable {
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

    case wmpClassic = "wmp-classic"
    case mediaPlayerClassic = "media-player-classic"
    case wmpGlass = "wmp-glass"
    case vlcClassic = "vlc-classic"
    case vlc
    case quicktime
    case itunesDisc = "itunes-disc"
    case itunes11 = "itunes-11"

    var id: String { rawValue }
    static let defaultChoice = Self.prismaticLight
    static let preferenceKey = "IconStyle"

    var alternateName: String? {
        if self == Self.defaultChoice { return nil }
        return rawValue.split(separator: "-").map { $0.capitalized }.joined()
    }

    var label: String {
        switch self {
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
        case .wmpClassic: "Windows Media Player 4"
        case .mediaPlayerClassic: "Media Player Classic"
        case .wmpGlass: "Windows Media Player Glass"
        case .vlcClassic: "VLC Classic"
        case .vlc: "VLC"
        case .quicktime: "QuickTime"
        case .itunesDisc: "iTunes Disc"
        case .itunes11: "iTunes 11"
        case .spotify: "Spotify"
        case .plex: "Plex"
        }
    }
}

#if os(macOS)
import AppKit

extension AppIconChoice {
    var macImage: NSImage? {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct MacAppIconGrid: View {
    @AppStorage(AppIconChoice.preferenceKey) private var iconStyle = AppIconChoice.defaultChoice.rawValue

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 91), spacing: 8)], spacing: 8) {
            ForEach(AppIconChoice.allCases) { choice in
                let selected = choice.rawValue == iconStyle
                Button {
                    iconStyle = choice.rawValue
                } label: {
                    VStack(spacing: 7) {
                        if let image = choice.macImage {
                            Image(nsImage: image)
                                .resizable().scaledToFit()
                                .frame(width: 55, height: 55)
                                .accessibilityHidden(true)
                        }
                        Text(choice.label)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .frame(minHeight: 28)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(7)
                    .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").padding(5).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
#endif

#if os(iOS) || os(tvOS)
import UIKit

struct MusicAppIconPicker: View {
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @Environment(\.dismiss) private var dismiss
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var changingIcon = false
    @State private var message: String?

    static func resetUnavailableIcon() async {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, let selected = app.alternateIconName,
              !AppIconChoice.allCases.contains(where: { $0.alternateName == selected }) else { return }
        try? await app.setAlternateIconName(nil)
    }

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
        .musicSheet(theme)
        .tint(theme.accent)
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
