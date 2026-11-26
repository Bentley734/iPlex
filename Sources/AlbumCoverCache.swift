import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AlbumCoverCache {
    static func location(server: String, library: String, path: String) -> URL {
        let key = SHA256.hash(data: Data("\(server)|\(library)|\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appending(path: "PlexAlbumCovers", directoryHint: .isDirectory)
            .appending(path: key + ".jpg")
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 420
        ] as CFDictionary)
    }

    static func save(_ data: Data, to url: URL) throws {
        guard let image = thumbnail(data) else { throw PlexServiceError("Invalid album cover.") }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PlexServiceError("Couldn’t prepare the album cover.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.83] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PlexServiceError("Couldn’t save the album cover.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (jpeg as Data).write(to: url, options: .atomic)
    }
}
