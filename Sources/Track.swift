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
    let plexID: String?
    let playlistItemID: String?
    let format: MusicTrackFormat

    init(number: Int, title: String, duration: TimeInterval?, url: URL, artworkPath: String? = nil,
         artist: String? = nil, album: String? = nil, ratingCount: Int = 0, id: UUID = UUID(),
         plexID: String? = nil, playlistItemID: String? = nil, format: MusicTrackFormat = MusicTrackFormat()) {
        self.id = id
        self.number = number
        self.title = title
        self.duration = duration
        self.url = url
        self.artworkPath = artworkPath
        self.artist = artist
        self.album = album
        self.ratingCount = ratingCount
        self.plexID = plexID
        self.playlistItemID = playlistItemID
        self.format = format
    }

    func queuedCopy() -> Self {
        Self(number: number, title: title, duration: duration, url: url, artworkPath: artworkPath,
             artist: artist, album: album, ratingCount: ratingCount, plexID: plexID, format: format)
    }

    var summary: [String: Any] {
        var item: [String: Any] = ["number": number, "title": title]
        if let duration { item["duration"] = duration }
        return item
    }
}

struct MusicTrackFormat {
    var codec: String?
    var container: String?
    var sampleRate: Int?
    var bitDepth: Int?
    var bitrate: Int?
    var channels: Int?

    var badge: String {
        let lossless = ["flac", "alac", "wav", "aiff", "ape", "wavpack"].contains(codec?.lowercased() ?? "")
            || (codec?.lowercased().hasPrefix("pcm") ?? false)
        if lossless && (sampleRate ?? 0) > 48_000 && (bitDepth ?? 0) > 16 { return "Hi-Res" }
        if lossless { return "Lossless" }
        return codec?.uppercased() ?? "Signal Path"
    }

    var details: String {
        [codec?.uppercased(), container?.uppercased(), bitDepth.map { "\($0)-bit" },
         sampleRate.map { Self.rateLabel(Double($0)) }, bitrate.map { "\($0) kbps" },
         channels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func rateLabel(_ rate: Double) -> String {
        (rate / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz"
    }
}

struct MusicLyricLine: Identifiable {
    let id: Int
    let time: Double?
    let text: String

    static func parse(_ raw: String) -> [Self] {
        let rows = raw.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
        var timed: [(Double, String)] = []
        var plain: [String] = []
        var offset = 0.0
        let stamp = try! NSRegularExpression(pattern: #"\[([0-9]{1,3}):([0-9]{1,2}(?:\.[0-9]{1,3})?)\]"#)
        for row in rows.prefix(10_000) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("[offset:"), trimmed.hasSuffix("]") {
                offset = (Double(trimmed.dropFirst(8).dropLast()) ?? 0) / 1000
                continue
            }
            let line = trimmed as NSString
            let matches = stamp.matches(in: trimmed, range: NSRange(location: 0, length: line.length))
            if let last = matches.last {
                let lyric = line.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
                for match in matches {
                    guard let minutes = Double(line.substring(with: match.range(at: 1))),
                          let seconds = Double(line.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                    timed.append((minutes * 60 + seconds, lyric))
                }
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("[") {
                plain.append(trimmed)
            }
        }
        if !timed.isEmpty {
            return timed.sorted { $0.0 < $1.0 }.enumerated().map { Self(id: $0.offset, time: max(0, $0.element.0 + offset), text: $0.element.1) }
        }
        return plain.enumerated().map { Self(id: $0.offset, time: nil, text: $0.element) }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
