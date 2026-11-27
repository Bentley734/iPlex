import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GlassWallpaper: Decodable {
    let id: String
    let title: String
    let file: String

    static let defaultID = "crimson-current"
    static let choices: [GlassWallpaper] = {
        guard let url = Bundle.main.url(forResource: "glass-wallpapers", withExtension: "json", subdirectory: "ToolDrive"),
              let data = try? Data(contentsOf: url),
              let choices = try? JSONDecoder().decode([GlassWallpaper].self, from: data) else { return [] }
        return choices
    }()
}

final class GlassWallpaperPreferences {
    static let shuffle = "shuffle"
    private let defaults: UserDefaults
    private let wallpaperIDs: [String]
    private var pickedThisLaunch = false

    init(defaults: UserDefaults, wallpaperIDs: [String]) {
        self.defaults = defaults
        self.wallpaperIDs = wallpaperIDs
    }

    var wallpaper: String {
        if let saved = defaults.string(forKey: "catalogGlassWallpaper"), wallpaperIDs.contains(saved) { return saved }
        return wallpaperIDs.first ?? GlassWallpaper.defaultID
    }

    var choice: String { defaults.bool(forKey: "catalogGlassWallpaperShuffle") ? Self.shuffle : wallpaper }

    func enterTheme() {
        guard choice == Self.shuffle, !pickedThisLaunch else { return }
        let previous = wallpaper
        let others = wallpaperIDs.filter { $0 != previous }
        guard let next = others.randomElement() ?? wallpaperIDs.first else { return }
        defaults.set(next, forKey: "catalogGlassWallpaper")
        pickedThisLaunch = true
    }

    @discardableResult
    func select(_ value: String) -> Bool {
        if value == Self.shuffle {
            guard !wallpaperIDs.isEmpty else { return false }
            defaults.set(true, forKey: "catalogGlassWallpaperShuffle")
            enterTheme()
        } else {
            guard wallpaperIDs.contains(value) else { return false }
            defaults.set(value, forKey: "catalogGlassWallpaper")
            defaults.set(false, forKey: "catalogGlassWallpaperShuffle")
            pickedThisLaunch = false
        }
        return true
    }
}

enum CustomBackground {
    static let maximumInputBytes = 24 * 1024 * 1024
    static let maximumOutputBytes = 2 * 1024 * 1024

    enum ImportError: LocalizedError {
        case tooLarge, invalidImage
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Choose an image smaller than 24 MB."
            case .invalidImage: return "This image could not be opened. Try a JPEG, PNG, or HEIC photo."
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumInputBytes + 1) ?? Data()
        guard data.count <= maximumInputBytes else { throw ImportError.tooLarge }
        return data
    }

    static func jpeg(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes else { throw ImportError.tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else { throw ImportError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImportError.invalidImage
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82,
                          kCGImageDestinationBackgroundColor: CGColor(gray: 0, alpha: 1)]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumOutputBytes else { throw ImportError.invalidImage }
        return output as Data
    }

    static func install(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
