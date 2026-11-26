import SwiftUI

enum MusicTheme: String, CaseIterable, Identifiable {
    case copper, classic, video
    #if os(macOS)
    case graphite
    #endif

    var id: String { rawValue }
    var usesClickWheel: Bool { self == .classic || self == .video }
    var label: String {
        switch self {
        case .copper: "Copper Groove"
        case .classic: "Classic iPod"
        case .video: "iPod Video"
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
        #if os(macOS)
        case .graphite: Color(red: 0.09, green: 0.095, blue: 0.103)
        #endif
        }
    }
    var backdrop: LinearGradient {
        let end: Color
        switch self {
        case .copper: end = Color(red: 0.075, green: 0.073, blue: 0.085)
        case .classic: end = Color(red: 0.96, green: 0.98, blue: 1)
        case .video: end = Color(red: 0.025, green: 0.037, blue: 0.066)
        #if os(macOS)
        case .graphite: end = Color(red: 0.055, green: 0.059, blue: 0.068)
        #endif
        }
        return LinearGradient(colors: [surface, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct MusicSettings: View {
    @ObservedObject var library: LibraryModel
    @AppStorage("MusicTheme") private var theme = MusicTheme.copper
    @AppStorage(HeaderMark.preferenceKey) private var headerMark = HeaderMark.none
    @AppStorage(HeaderMarkSize.preferenceKey) private var headerMarkSize = HeaderMarkSize.medium
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.title.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Theme", selection: $theme) {
                        ForEach(MusicTheme.allCases) { option in
                            Text(option.label).tag(option)
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
        .background(theme.backdrop)
        .tint(theme.accent)
        .preferredColorScheme(theme.scheme)
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
