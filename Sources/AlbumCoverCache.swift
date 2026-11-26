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

    struct Checkpoint: Codable {
        let revision: String
        let offset: Int
    }

    static func checkpointLocation(server: String, library: String, type: String) -> URL {
        location(server: server, library: library, path: "scan-" + type)
            .deletingPathExtension().appendingPathExtension("json")
    }

    static func resumeOffset(at url: URL, revision: String?) -> Int {
        guard let revision, let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.revision == revision, checkpoint.offset > 0 else { return 0 }
        return checkpoint.offset
    }

    static func saveCheckpoint(at url: URL, revision: String?, offset: Int) throws {
        guard let revision else { return }
        let data = try JSONEncoder().encode(Checkpoint(revision: revision, offset: offset))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
