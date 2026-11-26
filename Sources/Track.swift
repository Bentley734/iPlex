import Foundation

struct LiveTrack {
    let id: UUID
    let number: Int
    let title: String
    let duration: TimeInterval?
    let url: URL
    let artworkPath: String?
    let artist: String?
    let album: String?
    let ratingCount: Int

    init(number: Int, title: String, duration: TimeInterval?, url: URL, artworkPath: String? = nil,
         artist: String? = nil, album: String? = nil, ratingCount: Int = 0, id: UUID = UUID()) {
        self.id = id
        self.number = number
        self.title = title
        self.duration = duration
        self.url = url
        self.artworkPath = artworkPath
        self.artist = artist
        self.album = album
        self.ratingCount = ratingCount
    }

    func queuedCopy() -> Self {
        Self(number: number, title: title, duration: duration, url: url, artworkPath: artworkPath,
             artist: artist, album: album, ratingCount: ratingCount)
    }

    var summary: [String: Any] {
        var item: [String: Any] = ["number": number, "title": title]
        if let duration { item["duration"] = duration }
        return item
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
