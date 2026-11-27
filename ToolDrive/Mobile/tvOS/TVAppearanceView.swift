import SwiftUI

struct TVAppearanceView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedLogo: MobileLogo?
    @State private var sendingBackground = false
    @State private var backgroundError: String?
    @State private var logoPlacement = LogoPlacement.home
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 540), spacing: 26)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                HStack {
                    Text("Appearance").font(.largeTitle.bold())
                    Spacer()
                    Button("Done") { dismiss() }.accessibilityIdentifier("tv.appearance.done")
                }
                .focusSection()
                VStack(alignment: .leading, spacing: 22) {
                    Text("Theme").font(.title3.bold())
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(MobileTheme.selectableThemes) { theme in
                            artChoice(theme.title, selected: archive.theme == theme,
                                      id: "tv.theme." + theme.rawValue, action: { archive.selectTheme(theme) }) {
                                ArchiveThemeArtwork(theme: theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
                                    .overlay(alignment: .leading) {
                                        ArchiveBrandLogo(logo: archive.logo)
                                            .foregroundStyle(.white)
                                            .frame(width: 116, height: 38)
                                            .padding(16)
                                            .background(.black.opacity(0.58))
                                    }
                            }
                        }
                    }
                }.focusSection()
                GlassAppearanceControls { focusedLogo = .classic }

                VStack(alignment: .leading, spacing: 20) {
                    Text("Logo").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    LogoPlacementControls(placement: $logoPlacement)
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(MobileLogo.allCases) { logo in
                            let isHome = logoPlacement == .home
                            let activeLogo = isHome ? archive.logo : archive.topBarLogo
                            artChoice(logo.title, selected: activeLogo == logo,
                                      id: (isHome ? "tv.logo." : "tv.topBarLogo.") + logo.rawValue,
                                      action: {
                                          if isHome { archive.selectLogo(logo) }
                                          else { archive.selectTopBarLogo(logo) }
                                      }) {
                                ZStack {
                                    archive.theme.raised
                                    ArchiveBrandLogo(logo: logo)
                                        .foregroundStyle(archive.theme.text)
                                        .padding(18)
                                }
                            }
                            .focused($focusedLogo, equals: logo)
                        }
                    }
                }.focusSection()

                MobileAppIconPicker()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Custom Background").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    if let revision = archive.customBackgroundRevision {
                        ArchiveWallpaper(id: revision.uuidString, file: ArchiveStore.backgroundFile)
                            .frame(width: 320, height: 160).clipShape(.rect(cornerRadius: 12))
                        Text("Your photo is used across all themes.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 20) {
                        Button {
                            sendingBackground = true
                        } label: {
                            Label("Send Photo from Another Device", systemImage: "qrcode")
                        }
                        .accessibilityIdentifier("tv.background.send")
                        if archive.customBackgroundRevision != nil {
                            Button("Remove Custom Background") {
                                do { try archive.removeCustomBackground(); backgroundError = nil }
                                catch { backgroundError = error.localizedDescription }
                            }
                        }
                    }
                    if let backgroundError { Text(backgroundError).font(.caption) }
                }
                .focusSection()
                if archive.theme == .liquidGlass {
                    Text("Wallpaper").font(.title3.bold())
                    Button { archive.selectWallpaper(GlassWallpaperPreferences.shuffle) } label: {
                        Label(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? "Shuffle ✓" : "Shuffle",
                              systemImage: "shuffle")
                    }
                    .accessibilityLabel("Shuffle wallpaper on each launch")
                    .accessibilityAddTraits(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? .isSelected : [])
                    .accessibilityIdentifier("tv.wallpaper.shuffle")
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(GlassWallpaper.choices, id: \.id) { photo in
                            artChoice(photo.title, selected: photo.id == archive.wallpaperChoice,
                                      id: "tv.wallpaper." + photo.id, action: { archive.selectWallpaper(photo.id) }) {
                                ArchiveWallpaper(id: photo.id)
                            }
                        }
                    }.focusSection()
                }
            }
            .padding(50)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .sheet(isPresented: $sendingBackground) { TVBackgroundTransfer(archive: archive) }
        .onExitCommand { dismiss() }
    }

    private func artChoice<Artwork: View>(_ title: String, selected: Bool, id: String,
                                          action: @escaping () -> Void,
                                          @ViewBuilder art: () -> Artwork) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                art().frame(height: 118).clipped()
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(archive.resolvedAccent) }
                }
                .padding(14)
                .foregroundStyle(archive.theme.text)
                .background(archive.theme.panel)
            }
        }
        .buttonStyle(.card)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
