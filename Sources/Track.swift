import Foundation

struct LiveTrack {
    let number: Int
    let title: String
    let duration: TimeInterval?
    let url: URL

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
