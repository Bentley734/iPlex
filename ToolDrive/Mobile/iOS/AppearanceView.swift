import SwiftUI
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

struct ArchiveAboutView: View {
    @EnvironmentObject private var archive: ArchiveStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tool Drive Offline is an unofficial third-party app for the Tool Drive Project. This app is not associated with or endorsed by TOOL.")
                Text("Archive credits").font(.headline)
                Text("Geordy and Karl founded the project. Drew hosted its website, and Taylor and Jon helped modernize it. Thanks to the tapers, fans who shared the drives, and setlist.fm contributors.")
                Link("Tool Drive Project history and credits", destination: URL(string: "https://tooldriveproject.net/?page=about")!)
                Text("Visualizer credits").font(.headline)
                Text("These kaleidoscopes were inspired by Colliding Scopes by Alan (Stereo Drift), gbendy/kaleidoscope, and Ege Çetin’s libKaleidoscope. Mirrored Stage concert photography by Originate Designs Photography.")
                Link("Colliding Scopes", destination: URL(string: "https://collidingscopes.github.io/")!)
                Link("gbendy/kaleidoscope", destination: URL(string: "https://github.com/gbendy/kaleidoscope")!)
                Link("libKaleidoscope", destination: URL(string: "https://github.com/egecetin/libKaleidoscope")!)
            }.padding(22).frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .archivePage(wallpaperID: archive.wallpaperID)
        .navigationTitle("About")
    }
}

private func wallpaperThumbnail(_ file: String) -> UIImage? {
    guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "ToolDrive/Wallpapers"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 440,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
}

struct AppearanceView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var importingBackground = false
    @State private var backgroundError: String?
    @State private var logoPlacement = LogoPlacement.home

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 138, maximum: 360), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Theme")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(MobileTheme.allCases) { theme in
                                choice(theme.title, id: "theme." + theme.rawValue, selected: archive.theme == theme) {
                                    archive.selectTheme(theme)
                                } image: {
                                    ArchiveThemeArtwork(theme: theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
                                        .overlay(alignment: .bottomLeading) {
                                            Capsule().fill(theme.usesGlass ? archive.resolvedAccent : theme.accent).frame(width: 30, height: 4).padding(9)
                                        }
                                }
                            }
                        }
                        if archive.theme != .oledDark {
                            Toggle("Liquid Glass controls", isOn: Binding(get: { archive.glassEnabled }, set: archive.setGlassEnabled))
                                .padding(.horizontal, 14).padding(.vertical, 11).archivePanel()
                                .accessibilityIdentifier("appearance.glass")
                        }
                    }

                    if archive.theme.usesGlass { GlassAppearanceControls() }

                    VStack(alignment: .leading, spacing: 10) {
                        heading("Logo")
                        LogoPlacementControls(placement: $logoPlacement)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(MobileLogo.allCases) { logo in
                                let isHome = logoPlacement == .home
                                let activeLogo = isHome ? archive.logo : archive.topBarLogo
                                choice(logo.title, id: (isHome ? "logo." : "topBarLogo.") + logo.rawValue, selected: activeLogo == logo) {
                                    if isHome { archive.selectLogo(logo) }
                                    else { archive.selectTopBarLogo(logo) }
                                } image: {
                                    ZStack {
                                        archive.theme.panel
                                        ArchiveBrandLogo(logo: logo).padding(12)
                                    }
                                }
                            }
                        }
                    }

                    MobileAppIconPicker()

                    customBackground

                    if archive.theme == .liquidGlass {
                        wallpapers
                    } else if archive.theme == .frontRow {
                        VStack(alignment: .leading, spacing: 10) {
                            heading("Front Row picture")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(FrontRowPicture.allCases) { picture in
                                    choice(picture.title, id: "picture." + picture.rawValue, selected: archive.picture == picture) {
                                        archive.selectPicture(picture)
                                    } image: {
                                        ArchiveThemeArtwork(theme: .frontRow, picture: picture, wallpaperID: archive.wallpaperID)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): importBackground { try CustomBackground.read(url) }
                case .failure(let error): backgroundError = error.localizedDescription
                }
            }
            .onChange(of: photo) { _, selection in
                guard let selection else { return }
                photo = nil
                importBackground {
                    guard let data = try await selection.loadTransferable(type: Data.self) else {
                        throw CustomBackground.ImportError.invalidImage
                    }
                    return data
                }
            }
            .task {
                thumbnails = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: GlassWallpaper.choices.compactMap { photo in
                        wallpaperThumbnail(photo.file).map { (photo.id, $0) }
                    })
                }.value
            }
        }
    }

    private var customBackground: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Custom Background")
            if let revision = archive.customBackgroundRevision {
                ArchiveWallpaper(id: revision.uuidString, file: ArchiveStore.backgroundFile)
                    .frame(height: 130).clipShape(.rect(cornerRadius: 12))
                Text("Your photo is used across all themes.").font(.footnote).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { backgroundActions }
                VStack(alignment: .leading) { backgroundActions }
            }
            .buttonStyle(.bordered)
            .disabled(importingBackground)
            if importingBackground { ProgressView("Importing photo…") }
            if let backgroundError { Text(backgroundError).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var backgroundActions: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Label("Choose from Photos", systemImage: "photo")
        }
        Button { choosingFile = true } label: { Label("Choose File", systemImage: "folder") }
        .accessibilityIdentifier("appearance.background.file")
        if archive.customBackgroundRevision != nil {
            Button("Remove Custom Background", role: .destructive) {
                do { try archive.removeCustomBackground(); backgroundError = nil }
                catch { backgroundError = error.localizedDescription }
            }
        }
    }

    private func importBackground(_ input: @escaping @Sendable () async throws -> Data) {
        guard !importingBackground else { return }
        importingBackground = true
        backgroundError = nil
        Task {
            defer { importingBackground = false }
            do { try await archive.importBackground(input) }
            catch { backgroundError = error.localizedDescription }
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Wallpaper")
            Button { archive.selectWallpaper(GlassWallpaperPreferences.shuffle) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shuffle").font(.title3).foregroundStyle(archive.resolvedAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shuffle").font(.headline)
                        Text("A different concert photo each launch.").font(.subheadline).foregroundStyle(archive.theme.muted)
                    }
                    Spacer()
                    if archive.wallpaperChoice == GlassWallpaperPreferences.shuffle {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(archive.resolvedAccent)
                    }
                }.padding(14).archivePanel()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appearance.wallpaper.shuffle")
            .accessibilityAddTraits(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? .isSelected : [])
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GlassWallpaper.choices, id: \.id) { photo in
                    choice(photo.title, id: "wallpaper." + photo.id, selected: archive.wallpaperChoice == photo.id) {
                        archive.selectWallpaper(photo.id)
                    } image: {
                        if let image = thumbnails[photo.id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { archive.theme.panel }
                    }
                }
            }
        }
    }

    private func heading(_ name: String) -> some View {
        Text(name).font(.title3.bold()).foregroundStyle(archive.theme.text).accessibilityAddTraits(.isHeader)
    }

    private func choice<Preview: View>(_ name: String, id: String, selected: Bool, action: @escaping () -> Void,
                                       @ViewBuilder image: () -> Preview) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(archive.theme.panel).aspectRatio(2.55, contentMode: .fit)
                    .overlay { image().accessibilityHidden(true) }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.black, archive.resolvedAccent).padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? archive.resolvedAccent : archive.theme.line,
                                                                       lineWidth: selected ? 2 : 1)
                    }
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(archive.theme.text)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("appearance." + id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
