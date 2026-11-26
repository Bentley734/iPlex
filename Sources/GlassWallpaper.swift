import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

@MainActor
final class GlassWallpaper: ObservableObject {
    static let shared = GlassWallpaper()
    @Published private(set) var image: MusicImage?
    @Published private(set) var working = false
    @Published private(set) var message: String?
    private var modified = false

    private init() {
        let file = Self.location
        Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            await self.restore(image)
        }
    }

    private func restore(_ artwork: CGImage) {
        if !modified && image == nil { image = MusicPlatform.image(artwork) }
    }

    private nonisolated static var location: URL {
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        return directory.appending(path: "iPlex", directoryHint: .isDirectory).appending(path: "GlassBackground.jpg")
    }

    func importFile(_ url: URL) {
        update {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true else { throw WallpaperError.invalid }
            guard (info.fileSize ?? 0) <= Self.maximumBytes else { throw WallpaperError.tooLarge }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    #if os(iOS)
    func importPhoto(_ selection: PhotosPickerItem) {
        update {
            guard let data = try await selection.loadTransferable(type: Data.self) else { throw WallpaperError.invalid }
            return data
        }
    }
    #endif

    #if os(tvOS)
    func importAddress(_ address: String) {
        update {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
                throw WallpaperError.address
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else { throw WallpaperError.invalid }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else { throw WallpaperError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw WallpaperError.tooLarge }
                data.append(byte)
            }
            return data
        }
    }
    #endif

    func remove() {
        guard !working else { return }
        do {
            try FileManager.default.removeItem(at: Self.location)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            message = "Couldn’t remove the background."
            return
        }
        modified = true
        image = nil
        message = nil
    }

    func reportPickerError(_ error: Error) {
        if (error as? CocoaError)?.code != .userCancelled {
            message = "Couldn’t open that image."
        }
    }

    private nonisolated static let maximumBytes = 25 * 1024 * 1024

    private func update(_ read: @escaping @Sendable () async throws -> Data) {
        guard !working else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let artwork = try await Task.detached(priority: .userInitiated) {
                    let data = try await read()
                    return try Self.save(data)
                }.value
                modified = true
                image = MusicPlatform.image(artwork)
            } catch {
                message = (error as? WallpaperError)?.errorDescription ?? "Couldn’t load the background image."
            }
        }
    }

    private nonisolated static func save(_ data: Data) throws -> CGImage {
        guard data.count <= maximumBytes else { throw WallpaperError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560
              ] as CFDictionary) else { throw WallpaperError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw WallpaperError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError.invalid }
        let file = location
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (output as Data).write(to: file, options: .atomic)
        return image
    }

    private enum WallpaperError: LocalizedError {
        case invalid, tooLarge, address

        var errorDescription: String? {
            switch self {
            case .invalid: "Choose a supported image file."
            case .tooLarge: "Choose an image smaller than 25 MB."
            case .address: "Enter an HTTPS link to an image."
            }
        }
    }
}

struct GlassWallpaperBackdrop: View {
    let image: MusicImage

    var body: some View {
        GeometryReader { geometry in
            GlassWallpaperImage(image: image)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(.black.opacity(0.40))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassWallpaperImage: View {
    let image: MusicImage

    var body: some View {
        #if os(macOS)
        Image(nsImage: image).resizable()
        #else
        Image(uiImage: image).resizable()
        #endif
    }
}

struct GlassWallpaperSettings: View {
    @ObservedObject private var wallpaper = GlassWallpaper.shared
    #if os(tvOS)
    @State private var address = ""
    #else
    @State private var showingFiles = false
    #endif
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Liquid Glass Background").font(.headline)
            if let image = wallpaper.image {
                GlassWallpaperImage(image: image)
                    .scaledToFill().frame(width: 132, height: 74)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Current Liquid Glass background")
            }
            #if os(tvOS)
            TextField("HTTPS image URL", text: $address).textContentType(.URL)
            Button("Set Background", systemImage: "photo") { wallpaper.importAddress(address) }
                .disabled(wallpaper.working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #else
            HStack {
                Button("Choose Image…", systemImage: "photo") { showingFiles = true }
                    .disabled(wallpaper.working)
                #if os(iOS)
                PhotosPicker(selection: $photo, matching: .images) { Label("Photos", systemImage: "photo.on.rectangle") }
                    .disabled(wallpaper.working)
                    .onChange(of: photo) { _, selection in
                        if let selection { wallpaper.importPhoto(selection) }
                        photo = nil
                    }
                #endif
            }
            #endif
            if wallpaper.image != nil {
                Button("Remove Background", systemImage: "xmark.circle", action: wallpaper.remove)
                    .disabled(wallpaper.working)
            }
            if wallpaper.working { ProgressView("Saving background…") }
            if let message = wallpaper.message { Text(message).foregroundStyle(.secondary) }
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): wallpaper.importFile(url)
            case .failure(let error): wallpaper.reportPickerError(error)
            }
        }
        #endif
    }
}
