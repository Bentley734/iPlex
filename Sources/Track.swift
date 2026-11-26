import Foundation

struct LiveTrack {
    let number: Int
    let title: String
    let duration: TimeInterval?
    let url: URL
    let artworkPath: String?
    let artist: String?
    let album: String?

    init(number: Int, title: String, duration: TimeInterval?, url: URL, artworkPath: String? = nil,
         artist: String? = nil, album: String? = nil) {
        self.number = number
        self.title = title
        self.duration = duration
        self.url = url
        self.artworkPath = artworkPath
        self.artist = artist
        self.album = album
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
