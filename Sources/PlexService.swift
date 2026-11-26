import Foundation
import Security

struct PlexServiceError: LocalizedError {
    let message: String
    let isCancellation: Bool
    let retryOtherConnection: Bool
    let noRecordingMatch: Bool
    let httpStatus: Int?

    init(_ message: String, isCancellation: Bool = false, retryOtherConnection: Bool = false, httpStatus: Int? = nil,
         noRecordingMatch: Bool = false) {
        self.message = message
        self.isCancellation = isCancellation
        self.noRecordingMatch = noRecordingMatch
        self.retryOtherConnection = retryOtherConnection
        self.httpStatus = httpStatus
    }

    static var canceled: PlexServiceError {
        PlexServiceError("The Plex request was canceled.", isCancellation: true)
    }

    static var expiredPIN: PlexServiceError {
        PlexServiceError("Plex sign-in expired. Start again to get a new code.")
    }

    var errorDescription: String? { message }
}

enum PlexSignInMethod {
    case browser, linkCode

    var pinURL: URL {
        switch self {
        case .browser: return URL(string: "https://plex.tv/api/v2/pins?strong=true")!
        case .linkCode: return URL(string: "https://plex.tv/api/v2/pins?strong=false")!
        }
    }
}

struct PlexAuthorizationSession: Equatable {
    let pinID: Int
    let authorizationURL: URL
    let code: String
    let expiresIn: Int
}

enum PlexAuthorizationPoll: Equatable {
    case pending
    case connected
}

struct PlexServer: Equatable {
    let id: String
    let name: String
    let owned: Bool
    let connectionCount: Int

    var summary: [String: Any] {
        ["id": id, "name": name, "owned": owned, "connectionCount": connectionCount]
    }

    static func restoredID(in servers: [PlexServer], preferred: String?) -> String? {
        if let preferred { return servers.contains { $0.id == preferred } ? preferred : nil }
        return servers.count == 1 ? servers[0].id : nil
    }
}

struct PlexLibrary: Equatable {
    let id: String
    let name: String

    static func restoredID(in libraries: [PlexLibrary], preferred: String?) -> String? {
        if let preferred { return libraries.contains { $0.id == preferred } ? preferred : nil }
        return libraries.count == 1 ? libraries[0].id : nil
    }
}

struct PlexTrackSummary: Equatable {
    let number: Int
    let title: String
    let duration: TimeInterval?

    var summary: [String: Any] {
        var value: [String: Any] = ["number": number, "title": title]
        if let duration = duration { value["duration"] = duration }
        return value
    }
}

struct PlexSearchResult {
    let showDate: String
    let version: Int
    let collection: String
    let tracks: [PlexTrackSummary]
    fileprivate let playbackTracks: [LiveTrack]

    var summary: [String: Any] {
        [
            "showDate": showDate,
            "version": version,
            "collection": collection,
            "tracks": tracks.map(\.summary)
        ]
    }

    // Native integration only. Do not serialize these URLs into WebKit messages.
    func withNativePlaybackTracks(_ body: ([LiveTrack]) -> Void) {
        body(playbackTracks)
    }

    func validatedPlaybackTracks() throws -> [LiveTrack] {
        try PlexParser.validatedPlaybackTracks(playbackTracks)
    }
}

struct PlexStatus: Equatable {
    let phase: String
    let connected: Bool
    let serverCount: Int
    let selectedServerID: String?
    let selectedServerName: String?
    let selectedLibraryID: String?
    let selectedLibraryName: String?
    let message: String

    var summary: [String: Any] {
        var value: [String: Any] = [
            "phase": phase,
            "connected": connected,
            "serverCount": serverCount,
            "message": message
        ]
        if let selectedServerID = selectedServerID { value["selectedServerID"] = selectedServerID }
        if let selectedServerName = selectedServerName { value["selectedServerName"] = selectedServerName }
        if let selectedLibraryID = selectedLibraryID { value["selectedLibraryID"] = selectedLibraryID }
        if let selectedLibraryName = selectedLibraryName { value["selectedLibraryName"] = selectedLibraryName }
        return value
    }
}

protocol PlexCredentialStore: AnyObject {
    func contains(_ account: String) throws -> Bool
    func value(for account: String) throws -> String?
    func setValue(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
    func removeValues(withPrefix prefix: String) throws
}

extension PlexCredentialStore {
    func contains(_ account: String) throws -> Bool { try value(for: account) != nil }
}

final class PlexKeychainStore: PlexCredentialStore {
    private let service = "net.bentley734.musicroom.plex"

    func contains(_ account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw PlexServiceError("Keychain could not check the Plex account.") }
        return true
    }

    func value(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PlexServiceError("The Plex credential could not be read from Keychain.")
        }
        return value
    }

    func setValue(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw PlexServiceError("The Plex credential is invalid.")
        }
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PlexServiceError("The Plex credential could not be updated in Keychain.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw PlexServiceError("The Plex credential could not be saved in Keychain.")
        }
    }

    func removeValue(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PlexServiceError("The Plex credential could not be removed from Keychain.")
        }
    }

    func removeValues(withPrefix prefix: String) throws {
        var query = baseQuery(account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw PlexServiceError("The Plex credentials could not be listed in Keychain.")
        }
        for attributes in result as? [[String: Any]] ?? [] {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            try removeValue(for: account)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account = account { query[kSecAttrAccount as String] = account }
        return query
    }
}

private struct PlexConnectionRecord: Equatable {
    let url: URL
    let local: Bool
    let relay: Bool

    var rank: Int {
        if relay { return 2 }
        return local ? 0 : 1
    }
}

private struct PlexServerRecord {
    let server: PlexServer
    let connections: [PlexConnectionRecord]
    let token: String
}

private struct PlexPinRecord {
    let id: Int
    let code: String
    let token: String?
    let expiresIn: Int?
}

private struct PlexPartRecord {
    let key: String
    let filePath: String
    let fileName: String
    let format: String
}

private struct PlexTrackRecord {
    let identity: String
    let albumIdentity: String
    let albumTitle: String
    let title: String
    let disc: Int
    let index: Int?
    let duration: TimeInterval?
    let part: PlexPartRecord
}

enum PlexParser {
    private static let supportedFormats: Set<String> = [
        "flac", "alac", "wav", "wave", "aif", "aiff", "mp3", "aac", "m4a", "mp4", "caf"
    ]

    static func pin(_ data: Data) throws -> (id: Int, code: String, hasToken: Bool) {
        let record = try pinRecord(data)
        return (record.id, record.code, record.token != nil)
    }

    static func authorizationSession(_ data: Data, clientIdentifier: String,
                                     method: PlexSignInMethod) throws -> PlexAuthorizationSession {
        let pin = try pinRecord(data)
        let url: URL
        switch method {
        case .browser:
            url = try authorizationURL(clientIdentifier: clientIdentifier, code: pin.code)
        case .linkCode:
            let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            guard pin.code.count == 4, pin.code.unicodeScalars.allSatisfy(allowed.contains) else {
                throw PlexServiceError("Plex returned an invalid TV link code. Try linking again.")
            }
            url = URL(string: "https://plex.tv/link")!
        }
        let expiresIn = pin.expiresIn ?? 300
        guard expiresIn > 0 else { throw PlexServiceError.expiredPIN }
        return PlexAuthorizationSession(pinID: pin.id, authorizationURL: url, code: pin.code,
                                        expiresIn: min(expiresIn, 86_400))
    }

    static func authorizationURL(clientIdentifier: String, code: String,
                                 product: String = "iPlex") throws -> URL {
        guard validIdentifier(clientIdentifier, maximum: 200), validIdentifier(code, maximum: 200) else {
            throw PlexServiceError("Plex returned an invalid authorization code.")
        }
        let product = clean(product, maximum: 100)
        guard !product.isEmpty else { throw PlexServiceError("The Plex application name is invalid.") }
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "clientID", value: clientIdentifier),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "context[device][product]", value: product)
        ]
        guard let encoded = query.percentEncodedQuery,
              let url = URL(string: "https://app.plex.tv/auth#?" + encoded),
              url.scheme == "https", url.host == "app.plex.tv" else {
            throw PlexServiceError("The Plex authorization page could not be created.")
        }
        return url
    }

    static func resources(_ data: Data) throws -> [PlexServer] {
        try resourceRecords(data).map(\.server)
    }

    static func libraries(_ data: Data) throws -> [PlexLibrary] {
        guard data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw PlexServiceError("Plex returned an invalid library list.")
        }
        if container["Directory"] == nil, integer(container["size"]) == 0 { return [] }
        guard let rows = container["Directory"] as? [[String: Any]], rows.count <= 2_000 else {
            throw PlexServiceError("Plex returned an invalid library list.")
        }
        var seen = Set<String>()
        return rows.compactMap { row -> PlexLibrary? in
            guard row["type"] as? String == "artist", let id = numericIdentifier(row["key"]),
                  let number = UInt(id), number > 0, String(number) == id,
                  let name = string(row["title"], maximum: 300), seen.insert(id).inserted else { return nil }
            return PlexLibrary(id: id, name: name)
        }.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    static func validatedConnection(_ value: String, local: Bool, relay: Bool) -> URL? {
        connection(value, local: local, relay: relay)?.url
    }

    static func validatedPartPath(_ value: String) -> String? {
        guard value.count <= 2_048,
              value.hasPrefix("/library/parts/"),
              !value.contains("\\"), !value.contains("?"), !value.contains("#"),
              let encoded = URLComponents(string: value),
              encoded.scheme == nil, encoded.host == nil, encoded.percentEncodedPath == value,
              let decoded = value.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("//") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 5,
              components[0].isEmpty,
              components[1] == "library", components[2] == "parts",
              components[3].count <= 20, !components[3].isEmpty,
              components[3].allSatisfy(\.isNumber),
              components.dropFirst(4).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 }) else {
            return nil
        }
        return value
    }

    static func albumKeys(_ data: Data, showDate: String, sectionID: String? = nil) throws -> [String] {
        try validateDate(showDate)
        let metadata = try metadataRows(data, sectionID: sectionID)
        var seen = Set<String>()
        return metadata.compactMap { row in
            guard (row["type"] as? String)?.lowercased() == "album",
                  let title = string(row["title"], maximum: 300), containsDate(showDate, in: title),
                  sectionID != nil || artistName(row).caseInsensitiveCompare("TOOL") == .orderedSame,
                  let key = numericIdentifier(row["ratingKey"]), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    static func search(_ data: Data, showDate: String, preferredVersion: Int?,
                       serverURL: URL, token: String, sectionID: String? = nil,
                       allowUnversionedAlbum: Bool = false) throws -> PlexSearchResult {
        let records = try trackRecords(data, showDate: showDate, sectionID: sectionID)
        return try search(records, showDate: showDate, preferredVersion: preferredVersion,
                          serverURL: serverURL, token: token, allowUnversionedAlbum: allowUnversionedAlbum)
    }

    static func searchQueries(showDate: String, preferredVersion: Int?) throws -> [String] {
        try validateDate(showDate)
        guard preferredVersion == nil || (0...999).contains(preferredVersion!) else {
            throw PlexServiceError("The Plex recording version is invalid.")
        }
        var queries = [String]()
        if let preferredVersion = preferredVersion {
            queries.append("tool\(showDate).v\(preferredVersion)")
        }
        queries.append("Tool \(showDate)")
        queries.append(showDate)
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    static func recording(in sectionID: String, showDate: String, preferredVersion: Int?,
                          allowUnversionedAlbum: Bool, serverURL: URL, token: String,
                          read: (String, [URLQueryItem]) throws -> Data) throws -> PlexSearchResult {
        try validateDate(showDate)
        let sectionPath = "/library/sections/\(sectionID)/all"
        var tracks = [PlexTrackRecord]()
        var albumIDs = Set<String>()
        // Plex may return just the first 20 tracks when /children is requested
        // without a page size. Consume every page before deciding what to play.
        func pages(_ path: String, _ query: [URLQueryItem], collect: (Data) throws -> Void) throws {
            let pageSize = 200
            var offset = 0
            while true {
                let data = try read(path, query + [URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
                                                   URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize))])
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let container = root["MediaContainer"] as? [String: Any] else {
                    throw PlexServiceError("Plex returned invalid library results.")
                }
                if let start = integer(container["offset"]), start != offset {
                    throw PlexServiceError("Plex returned an unexpected results page. Try again.")
                }
                try collect(data)
                let count = (container["Metadata"] as? [[String: Any]])?.count ?? 0
                let total = integer(container["totalSize"])
                let next = offset + count
                if let total, next >= total { return }
                if total == nil && count < pageSize { return }
                guard count > 0, next > offset, next < 100_000 else {
                    throw PlexServiceError("The Plex results could not be read completely. Try again.")
                }
                offset = next
            }
        }
        func loadAlbum(_ id: String) throws {
            try pages("/library/metadata/\(id)/children", []) {
                tracks += try trackRecords($0, showDate: showDate, sectionID: sectionID)
            }
        }
        func match(allowUnversioned: Bool) throws -> PlexSearchResult {
            try search(tracks, showDate: showDate, preferredVersion: preferredVersion, serverURL: serverURL,
                       token: token, allowUnversionedAlbum: allowUnversioned)
        }
        try pages(sectionPath, [URLQueryItem(name: "type", value: "9"),
                                URLQueryItem(name: "title", value: String(showDate.prefix(4)))]) {
            albumIDs.formUnion(try albumKeys($0, showDate: showDate, sectionID: sectionID))
        }
        for id in albumIDs.sorted() { try loadAlbum(id) }
        do { return try match(allowUnversioned: false) }
        catch let error as PlexServiceError where error.noRecordingMatch { }

        // Untagged archive imports often expose only the original stem as a
        // track title. Expand album hits so a partial search cannot truncate the queue.
        var trackAlbums = Set<String>()
        try pages(sectionPath, [URLQueryItem(name: "type", value: "10"),
                                URLQueryItem(name: "title", value: showDate)]) {
            let hits = try trackRecords($0, showDate: showDate, sectionID: sectionID)
            tracks += hits
            trackAlbums.formUnion(hits.compactMap { numericIdentifier($0.albumIdentity) })
        }
        for id in trackAlbums.subtracting(albumIDs).sorted() { try loadAlbum(id) }
        return try match(allowUnversioned: allowUnversionedAlbum)
    }

    static func validatedPlaybackTracks(_ supplied: [LiveTrack], maximum: Int = 250) throws -> [LiveTrack] {
        guard !supplied.isEmpty, supplied.count <= maximum else {
            throw PlexServiceError("A Plex recording must contain between 1 and \(maximum) tracks.")
        }
        var numbers = Set<Int>()
        return try supplied.map { track in
            guard track.number > 0, track.number <= max(999, maximum), numbers.insert(track.number).inserted else {
                throw PlexServiceError("The Plex recording contains a duplicate or invalid track number.")
            }
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 300,
                  track.duration == nil || (track.duration!.isFinite && (0...86_400).contains(track.duration!)),
                  var components = URLComponents(url: track.url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil, components.fragment == nil,
                  validatedPartPath(components.percentEncodedPath) != nil,
                  supportedFormats.contains(track.url.pathExtension.lowercased()),
                  let query = components.queryItems, query.count == 1,
                  query[0].name == "X-Plex-Token", let token = query[0].value, validToken(token) else {
                throw PlexServiceError("A Plex playback track is invalid or unsupported.")
            }
            components.percentEncodedPath = ""
            components.query = nil
            guard let base = components.url,
                  connection(base.absoluteString, local: false, relay: false) != nil else {
                throw PlexServiceError("A Plex playback track uses an untrusted server address.")
            }
            // Preserve the original, already authenticated URL. UI callbacks use LiveTrack.summary, which omits it.
            return LiveTrack(number: track.number, title: title, duration: track.duration, url: track.url)
        }
    }

    fileprivate static func pinRecord(_ data: Data) throws -> PlexPinRecord {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = integer(root["id"]), id > 0,
              let code = string(root["code"], maximum: 200), validIdentifier(code, maximum: 200) else {
            throw PlexServiceError("Plex returned an invalid authorization response.")
        }
        let rawToken = root["authToken"] ?? root["auth_token"]
        let token: String?
        if rawToken == nil || rawToken is NSNull { token = nil }
        else {
            guard let value = rawToken as? String, validToken(value) else {
                throw PlexServiceError("Plex returned an invalid account credential.")
            }
            token = value
        }
        return PlexPinRecord(id: id, code: code, token: token, expiresIn: integer(root["expiresIn"]))
    }

    fileprivate static func resourceRecords(_ data: Data) throws -> [PlexServerRecord] {
        guard data.count <= 2 * 1024 * 1024,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 100 else {
            throw PlexServiceError("Plex returned an invalid server list.")
        }
        var identifiers = Set<String>()
        var records = [PlexServerRecord]()
        for row in rows {
            let provides = (row["provides"] as? String ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard provides.contains("server"),
                  let identifier = string(row["clientIdentifier"], maximum: 200),
                  validIdentifier(identifier, maximum: 200), identifiers.insert(identifier).inserted,
                  let token = string(row["accessToken"], maximum: 8_192), validToken(token),
                  let rawConnections = row["connections"] as? [[String: Any]],
                  rawConnections.count <= 32 else { continue }
            let connections = rawConnections.compactMap { raw -> PlexConnectionRecord? in
                guard let uri = string(raw["uri"], maximum: 2_048) else { return nil }
                return connection(uri, local: boolean(raw["local"]), relay: boolean(raw["relay"]))
            }.sorted { lhs, rhs in
                lhs.rank == rhs.rank ? lhs.url.absoluteString < rhs.url.absoluteString : lhs.rank < rhs.rank
            }
            guard !connections.isEmpty else { continue }
            let name = string(row["name"], maximum: 200).flatMap { $0.isEmpty ? nil : $0 } ?? "Plex Media Server"
            let server = PlexServer(id: identifier, name: name, owned: boolean(row["owned"]),
                                    connectionCount: connections.count)
            records.append(PlexServerRecord(server: server, connections: connections, token: token))
        }
        guard !records.isEmpty else { throw PlexServiceError("No reachable Plex Media Server was found.") }
        return records.sorted {
            if $0.server.owned != $1.server.owned {
                return $0.server.owned && !$1.server.owned
            }
            return $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
        }
    }

    // The server's album title filter is a substring search. Check the complete
    // year/month/day locally so releases from a different day cannot match.
    private static let textDate = try! NSRegularExpression(pattern:
        #"(?<![0-9])(?:((?:19|20)\d\d)[._/ -]?(0[1-9]|1[0-2])[._/ -]?(0[1-9]|[12]\d|3[01])|(0[1-9]|1[0-2])[._/ -](0[1-9]|[12]\d|3[01])[._/ -]((?:19|20)\d\d))(?![0-9])"#)

    private static func dates(in text: String) -> Set<String> {
        let nsText = text as NSString
        return Set(textDate.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let parts = match.range(at: 1).location == NSNotFound ? [6,4,5] : [1,2,3]
            return parts.map { nsText.substring(with: match.range(at: $0)) }.joined(separator: "-")
        })
    }

    private static func containsDate(_ date: String, in text: String) -> Bool {
        dates(in: text) == [date]
    }

    private static func albumDirectory(_ path: String) -> String {
        var components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").dropLast()
        if let leaf = components.last, leaf.range(of: #"^(?:disc|disk|cd)[ ._-]*[0-9]+$"#,
                                                   options: [.regularExpression, .caseInsensitive]) != nil {
            components = components.dropLast()
        }
        return components.joined(separator: "/")
    }

    fileprivate static func trackRecords(_ data: Data, showDate: String, sectionID: String? = nil) throws -> [PlexTrackRecord] {
        try validateDate(showDate)
        return try metadataRows(data, sectionID: sectionID).compactMap { row in
            guard (row["type"] as? String)?.lowercased() == "track",
                  let identity = numericIdentifier(row["ratingKey"]),
                  let title = string(row["title"], maximum: 300),
                  let mediaRows = row["Media"] as? [[String: Any]], mediaRows.count <= 16 else { return nil }
            let albumTitle = string(row["parentTitle"], maximum: 300) ?? ""
            let toolArtist = artistName(row).caseInsensitiveCompare("TOOL") == .orderedSame
            let datedAlbum = containsDate(showDate, in: albumTitle)
            let albumID = numericIdentifier(row["parentRatingKey"])
            for media in mediaRows {
                guard let parts = media["Part"] as? [[String: Any]], parts.count <= 16 else { continue }
                for part in parts {
                    guard let keyValue = string(part["key"], maximum: 2_048),
                          let key = validatedPartPath(keyValue) else { continue }
                    let file = string(part["file"], maximum: 8_192) ?? ""
                    let folder = albumDirectory(file)
                    let leaf = folder.split(separator: "/").last.map(String.init) ?? ""
                    guard (toolArtist && (datedAlbum || containsDate(showDate, in: leaf))) ||
                            exactArchiveHierarchy(file, showDate: showDate) else { continue }
                    guard albumID != nil || !folder.isEmpty else { continue }
                    let fileName = (file.isEmpty ? key : file).replacingOccurrences(of: "\\", with: "/")
                        .split(separator: "/").last.map(String.init) ?? ""
                    let format = (string(part["container"], maximum: 20)
                                  ?? string(media["container"], maximum: 20)
                                  ?? URL(fileURLWithPath: fileName).pathExtension).lowercased()
                    return PlexTrackRecord(identity: identity, albumIdentity: albumID ?? folder,
                                           albumTitle: albumTitle, title: title,
                                           disc: integer(row["parentIndex"]) ?? 1, index: integer(row["index"]),
                                           duration: milliseconds(row["duration"]),
                                           part: PlexPartRecord(key: key, filePath: file, fileName: fileName, format: format))
                }
            }
            return nil
        }
    }

    private static let archiveFile = try! NSRegularExpression(
        pattern: #"(?i)^tool(\d{4}-\d{2}-\d{2})\.v(\d{1,3})\.t(\d{1,3})\.[a-z0-9]{2,8}$"#)
    private static let versionTag = try! NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9])v(?:ersion)?[ ._-]*(\d{1,3})(?![a-z0-9])"#)

    fileprivate static func search(_ records: [PlexTrackRecord], showDate: String,
                                   preferredVersion: Int?, serverURL: URL, token: String,
                                   allowUnversionedAlbum: Bool) throws -> PlexSearchResult {
        try validateDate(showDate)
        guard preferredVersion.map({ (0...999).contains($0) }) ?? true,
              validToken(token),
              let trustedBase = connection(serverURL.absoluteString, local: false, relay: false)?.url else {
            throw PlexServiceError("The Plex playback request is invalid.")
        }
        // Canonical archive files identify themselves. For retagged tracks use
        // a dated TOOL album/folder, its version tag, and Plex's disc/track order.
        struct Candidate {
            let record: PlexTrackRecord
            let version: Int
            let disc: Int
            let number: Int
            let evidence: Int   // 4: original archive path, 3: archive name, 2: version tag, 1: unversioned
        }
        var grouped = [String: [Candidate]]()
        var seenParts = Set<String>()
        for record in records {
            let name = record.part.fileName
            let folder = albumDirectory(record.part.filePath).split(separator: "/").last.map(String.init) ?? ""
            let version: Int
            let number: Int
            let disc: Int
            let evidence: Int
            let range = NSRange(name.startIndex..., in: name)
            if let match = archiveFile.firstMatch(in: name, range: range) {
                let nsName = name as NSString
                guard nsName.substring(with: match.range(at: 1)) == showDate,
                      let v = Int(nsName.substring(with: match.range(at: 2))),
                      let n = Int(nsName.substring(with: match.range(at: 3))) else { continue }
                version = v
                number = n
                disc = 1
                evidence = exactArchiveHierarchy(record.part.filePath, showDate: showDate) ? 4 : 3
            } else {
                let tags = record.albumTitle + "\n" + folder
                guard dates(in: tags + "\n" + name) == [showDate] else { continue }
                let versions = Set(versionTag.matches(in: tags, range: NSRange(tags.startIndex..., in: tags)).compactMap {
                    Int((tags as NSString).substring(with: $0.range(at: 1)))
                })
                if versions.count == 1, let v = versions.first {
                    version = v
                    evidence = 2
                } else if versions.isEmpty, allowUnversionedAlbum, let v = preferredVersion {
                    version = v
                    evidence = 1
                } else { continue }
                number = record.index ?? 0
                disc = record.disc
            }
            guard preferredVersion == nil || version == preferredVersion,
                  seenParts.insert(record.identity + "|" + record.part.key).inserted else { continue }
            grouped[record.albumIdentity + "|v\(version)", default: []].append(
                Candidate(record: record, version: version, disc: disc, number: number, evidence: evidence))
        }
        guard !grouped.isEmpty else {
            let version = preferredVersion.map { " (v\($0))" } ?? ""
            throw PlexServiceError("No matching TOOL recording for \(showDate)\(version) was found in this Plex music library.",
                                   noRecordingMatch: true)
        }
        // A versionless manual search historically chooses the fullest recording.
        // A specific source must never be resolved by guessing between albums.
        let ranked = grouped.values.sorted { left, right in
            let a = left.map(\.evidence).max()!, b = right.map(\.evidence).max()!
            if a != b { return a > b }
            if left.count != right.count { return left.count > right.count }
            if left[0].version != right[0].version { return left[0].version < right[0].version }
            return left[0].record.albumIdentity < right[0].record.albumIdentity
        }
        let best = ranked[0]
        if preferredVersion != nil, ranked.count > 1,
           best.map(\.evidence).max() == ranked[1].map(\.evidence).max() {
            throw PlexServiceError("More than one Plex album matches this recording. Give the albums distinct recording version tags.")
        }
        let ordered = best.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
        guard ordered.count <= 250, Set(ordered.map { $0.record.identity }).count == ordered.count,
              ordered.allSatisfy({ (1...999).contains($0.number) && (1...999).contains($0.disc) }),
              Set(ordered.map { $0.disc * 1_000 + $0.number }).count == ordered.count else {
            throw PlexServiceError("Plex could not determine the track order for this recording. Check its disc and track numbers.")
        }
        guard ordered.allSatisfy({ supportedFormats.contains($0.record.part.format) }) else {
            throw PlexServiceError("This Plex recording uses a format that cannot be played directly. Transcoding is not enabled.")
        }
        let numberedAcrossDiscs = ordered.first?.disc != ordered.last?.disc
        var playback = [LiveTrack]()
        var summaries = [PlexTrackSummary]()
        for (offset, candidate) in ordered.enumerated() {
            let url = try playbackURL(base: trustedBase, partPath: candidate.record.part.key, token: token)
            let summary = PlexTrackSummary(number: numberedAcrossDiscs ? offset + 1 : candidate.number,
                                           title: candidate.record.title, duration: candidate.record.duration)
            summaries.append(summary)
            playback.append(LiveTrack(number: summary.number, title: summary.title, duration: summary.duration, url: url))
        }
        let version = best[0].version
        let album = best[0].record.albumTitle
        let collection = containsDate(showDate, in: album) ? album : "TOOL \(showDate)"
        return PlexSearchResult(showDate: showDate, version: version, collection: collection + " · v\(version)",
                                tracks: summaries, playbackTracks: playback)
    }

    private static func playbackURL(base: URL, partPath: String, token: String) throws -> URL {
        guard let path = validatedPartPath(partPath), validToken(token),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PlexServiceError("A Plex media path is invalid.")
        }
        components.percentEncodedPath = path
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let url = components.url else { throw PlexServiceError("A Plex playback URL is invalid.") }
        return url
    }

    private static func exactArchiveHierarchy(_ file: String, showDate: String) -> Bool {
        let components = file.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[components.count - 3] == String(showDate.prefix(4)) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: showDate)
        let folderPattern = "(?i)^tool" + escaped + "\\.v[0-9]{1,3}$"
        let filePattern = "(?i)^tool" + escaped + "\\.v[0-9]{1,3}\\.t[0-9]{1,3}\\.[a-z0-9]{2,8}$"
        let folder = components[components.count - 2]
        let fileName = components[components.count - 1]
        return folder.range(of: folderPattern, options: .regularExpression) != nil
            && fileName.range(of: filePattern, options: .regularExpression) != nil
            && fileName.lowercased().hasPrefix(folder.lowercased() + ".t")
    }

    private static func metadataContainer(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw PlexServiceError("Plex returned invalid library results.")
        }
        return container
    }

    private static func metadataRows(_ data: Data, sectionID: String?) throws -> [[String: Any]] {
        try metadataRows(metadataContainer(data), sectionID: sectionID)
    }

    private static func metadataRows(_ container: [String: Any], sectionID: String?) throws -> [[String: Any]] {
        // Section-scoped endpoints sometimes place the identifier only on the container.
        func belongsToSection(_ item: [String: Any]) -> Bool {
            guard let sectionID = sectionID, let supplied = item["librarySectionID"] else { return true }
            return numericIdentifier(supplied) == sectionID
        }
        guard belongsToSection(container) else { return [] }
        var rows = container["Metadata"] as? [[String: Any]] ?? []
        if let hubs = container["Hub"] as? [[String: Any]] {
            guard hubs.count <= 100 else { throw PlexServiceError("Plex returned too many search groups.") }
            for hub in hubs {
                guard belongsToSection(hub),
                      let metadata = hub["Metadata"] as? [[String: Any]], metadata.count <= 500 else { continue }
                rows.append(contentsOf: metadata)
            }
        }
        guard rows.count <= 2_000 else { throw PlexServiceError("Plex returned too many search results.") }
        return rows.filter(belongsToSection)
    }

    private static func connection(_ value: String, local: Bool, relay: Bool) -> PlexConnectionRecord? {
        guard value.count <= 2_048,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) != false else { return nil }
        guard scheme == "https", host == "plex.direct" || host.hasSuffix(".plex.direct") else { return nil }
        var canonical = components
        canonical.scheme = scheme
        canonical.host = host
        canonical.path = ""
        guard let url = canonical.url else { return nil }
        return PlexConnectionRecord(url: url, local: local, relay: relay)
    }

    private static func validateDate(_ value: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw PlexServiceError("The Plex show date is invalid.")
        }
    }

    private static func numericIdentifier(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty, value.count <= 20, value.allSatisfy(\.isNumber) { return value }
        if let value = integer(value), value > 0 { return String(value) }
        return nil
    }

    private static func artistName(_ row: [String: Any]) -> String {
        for key in ["grandparentTitle", "originalTitle", "parentTitle"] {
            if let value = string(row[key], maximum: 300), value.caseInsensitiveCompare("TOOL") == .orderedSame {
                return value
            }
        }
        return ""
    }

    private static func clean(_ value: String, maximum: Int) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maximum,
              cleaned.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return cleaned
    }

    private static func string(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String else { return nil }
        let result = clean(value, maximum: maximum)
        return result.isEmpty ? nil : result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> TimeInterval? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number.flatMap { $0.isFinite && (0...86_400_000).contains($0) ? $0 / 1_000 : nil }
    }

    private static func boolean(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return value.count >= 4 && value.count <= maximum
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validToken(_ value: String) -> Bool {
        value.count >= 8 && value.count <= 8_192
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

final class PlexRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var canceled = false
    private var data = Data()
    private var error: Error?
    private var task: URLSessionDataTask?
    private var semaphore: DispatchSemaphore?
    private var limit = 0

    func cancel() {
        lock.lock(); canceled = true; let current = task; lock.unlock()
        current?.cancel()
    }

    func checkCancellation() throws {
        lock.lock(); let stopped = canceled; lock.unlock()
        if stopped { throw PlexServiceError.canceled }
    }

    func fetch(_ request: URLRequest, limit: Int, timeout: TimeInterval = 25) throws -> Data {
        lock.lock(); let wasCanceled = canceled; lock.unlock()
        if wasCanceled { throw PlexServiceError.canceled }
        self.limit = limit
        data = Data()
        error = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        semaphore = done
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let nowCanceled = canceled; lock.unlock()
        if nowCanceled { throw PlexServiceError.canceled }
        task.resume()
        guard done.wait(timeout: .now() + timeout + 10) == .success else {
            task.cancel()
            throw PlexServiceError("The Plex server did not respond in time.", retryOtherConnection: true)
        }
        lock.lock(); let finallyCanceled = canceled; lock.unlock()
        if finallyCanceled { throw PlexServiceError.canceled }
        if let error = error { throw error }
        return data
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            error = PlexServiceError("Plex returned an invalid response.")
            completionHandler(.cancel)
            return
        }
        let created = dataTask.originalRequest?.httpMethod == "POST" && http.statusCode == 201
        guard http.statusCode == 200 || created else {
            error = PlexServiceError("Plex returned HTTP \(http.statusCode).", retryOtherConnection: true,
                                     httpStatus: http.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            error = PlexServiceError("The Plex response exceeded its size limit.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > limit {
            error = PlexServiceError("The Plex response exceeded its size limit.")
            dataTask.cancel()
        } else { data.append(chunk) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError received: Error?) {
        if error == nil, let received = received {
            let message: String
            switch (received as? URLError)?.code {
            case .timedOut: message = "The Plex server timed out."
            case .cannotFindHost, .dnsLookupFailed: message = "The Plex server’s address could not be resolved."
            case .cannotConnectToHost: message = "The Plex server refused the connection or is unreachable."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                message = "A secure connection to the Plex server could not be verified."
            case .notConnectedToInternet, .dataNotAllowed:
                message = "Network access is unavailable. Check the network and this app’s Local Network permission."
            case .networkConnectionLost: message = "The connection to the Plex server was interrupted."
            default: message = "The Plex request failed. Check the server connection and try again."
            }
            error = PlexServiceError(message, retryOtherConnection: true)
        }
        semaphore?.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class PlexService {
    typealias StatusHandler = (PlexStatus) -> Void

    var onStatusChange: StatusHandler?

    private static let accountKey = "account"
    private static let preferredServerKey = "PlexPreferredServer"
    private static let serverKeyPrefix = "server:"
    private let clientIdentifier: String
    private let version: String
    private let credentials: PlexCredentialStore
    private var hasAccount: Bool
    private let work = DispatchQueue(label: "net.bentley734.musicroom.plex", qos: .utility)
    private let lock = NSLock()
    private var records = [String: PlexServerRecord]()
    private var selectedID: String?
    private var libraries = [PlexLibrary]()
    private var selectedLibraryID: String?
    private var workingConnection: URL?
    private var phase = "disconnected"
    private var message = ""
    private var generation = 0
    private var operation: PlexRequestOperation?
    private var cancellationHandler: (() -> Void)?

    init(clientIdentifier: String? = nil, version: String = "1.0",
         credentials: PlexCredentialStore = PlexKeychainStore()) {
        self.clientIdentifier = clientIdentifier ?? Self.persistentClientIdentifier()
        self.version = version
        self.credentials = credentials
        hasAccount = (try? credentials.contains(Self.accountKey)) == true
        phase = hasAccount ? "connected" : "disconnected"
    }

    deinit { cancelCurrentRequest(notify: false) }

    var status: PlexStatus {
        lock.lock(); defer { lock.unlock() }
        return statusLocked()
    }

    func beginConnection(method: PlexSignInMethod = .browser,
                         completion: @escaping (Result<PlexAuthorizationSession, Error>) -> Void) {
        lock.lock()
        records.removeAll()
        selectedID = nil
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        lock.unlock()
        let request = authorizedRequest(url: method.pinURL, method: "POST", token: nil)
        run(phase: "authorizing", message: "Waiting for Plex sign-in…", request: request,
            limit: 256 * 1024) { [weak self] data -> PlexAuthorizationSession in
            guard let self = self else { throw PlexServiceError("The Plex connection was canceled.") }
            return try PlexParser.authorizationSession(data, clientIdentifier: self.clientIdentifier, method: method)
        } completion: { [weak self] result in
            if case .failure(let error) = result,
               (error as? PlexServiceError)?.isCancellation != true {
                self?.setFailure(error.localizedDescription)
            }
            completion(result)
        }
    }

    func pollConnection(pinID: Int, completion: @escaping (Result<PlexAuthorizationPoll, Error>) -> Void) {
        guard pinID > 0,
              let url = URL(string: "https://plex.tv/api/v2/pins/\(pinID)") else {
            completion(.failure(PlexServiceError("The Plex authorization request is invalid.")))
            return
        }
        let request = authorizedRequest(url: url, method: "GET", token: nil)
        run(phase: "authorizing", message: "Waiting for Plex sign-in…", request: request,
            limit: 256 * 1024) { data -> PlexPinRecord in
            let pin = try PlexParser.pinRecord(data)
            guard pin.id == pinID else { throw PlexServiceError("Plex returned a mismatched authorization response.") }
            return pin
        } completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let pin):
                if pin.token == nil, let remaining = pin.expiresIn, remaining <= 0 {
                    self.setFailure(PlexServiceError.expiredPIN.localizedDescription)
                    completion(.failure(PlexServiceError.expiredPIN))
                    return
                }
                guard let token = pin.token else { completion(.success(.pending)); return }
                do {
                    try self.credentials.setValue(token, for: Self.accountKey)
                    self.lock.lock()
                    self.hasAccount = true
                    self.lock.unlock()
                    self.setPhase("connected", message: "Connected to Plex.")
                    completion(.success(.connected))
                } catch {
                    self.setFailure(error.localizedDescription)
                    completion(.failure(error))
                }
            case .failure(let error):
                if let status = (error as? PlexServiceError)?.httpStatus, status == 404 || status == 410 {
                    self.setFailure(PlexServiceError.expiredPIN.localizedDescription)
                    completion(.failure(PlexServiceError.expiredPIN))
                    return
                }
                if (error as? PlexServiceError)?.isCancellation != true {
                    self.setFailure(error.localizedDescription)
                }
                completion(.failure(error))
            }
        }
    }

    func refreshServers(_ completion: @escaping (Result<[PlexServer], Error>) -> Void) {
        cancelCurrentRequest()
        lock.lock()
        records.removeAll()
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        lock.unlock()
        let token: String
        do {
            guard let stored = try credentials.value(for: Self.accountKey) else {
                throw PlexServiceError("Connect a Plex account first.")
            }
            token = stored
        } catch {
            lock.lock()
            hasAccount = false
            lock.unlock()
            setFailure(error.localizedDescription)
            completion(.failure(error)); return
        }
        var components = URLComponents(string: "https://clients.plex.tv/api/v2/resources")!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "1")
        ]
        let request = authorizedRequest(url: components.url!, method: "GET", token: token)
        run(phase: "loadingServers", message: "Finding Plex servers…", request: request,
            limit: 2 * 1024 * 1024) { data -> [PlexServerRecord] in
            try PlexParser.resourceRecords(data)
        } completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let parsed):
                self.lock.lock()
                self.records = Dictionary(uniqueKeysWithValues: parsed.map { ($0.server.id, $0) })
                self.hasAccount = true
                let saved = UserDefaults.standard.string(forKey: Self.preferredServerKey)
                self.selectedID = PlexServer.restoredID(in: parsed.map(\.server), preferred: saved)
                if saved == nil, let selected = self.selectedID {
                    UserDefaults.standard.set(selected, forKey: Self.preferredServerKey)
                }
                self.lock.unlock()
                self.setPhase("connected", message: "Plex servers are ready.")
                completion(.success(parsed.map(\.server)))
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true {
                    self.setFailure(error.localizedDescription)
                }
                completion(.failure(error))
            }
        }
    }

    func selectServer(id: String) throws {
        lock.lock()
        let available = records[id] != nil
        lock.unlock()
        guard available else { throw PlexServiceError("That Plex server is unavailable.") }
        cancelCurrentRequest()
        lock.lock()
        guard records[id] != nil else { lock.unlock(); throw PlexServiceError("That Plex server is unavailable.") }
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.preferredServerKey)
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        phase = "connected"
        message = "Plex server selected."
        let value = statusLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
    }

    func refreshLibraries(_ completion: @escaping (Result<[PlexLibrary], Error>) -> Void) {
        cancelCurrentRequest()
        let record: PlexServerRecord
        do { record = try selectedServerAccess() }
        catch { completion(.failure(error)); return }
        lock.lock()
        libraries = []
        selectedLibraryID = nil
        lock.unlock()
        run(phase: "loadingLibraries", message: "Finding music libraries…", perform: { operation in
            try self.withConnection(record: record) { base -> ([PlexLibrary], URL) in
                let request = try self.serverRequest(base: base, path: "/library/sections", query: [], token: record.token)
                return (try PlexParser.libraries(operation.fetch(request, limit: 2 * 1024 * 1024, timeout: 8)), base)
            }
        }) { result in
            switch result {
            case .success(let (available, base)):
                let preference = UserDefaults.standard.string(forKey: "PlexMusicLibrary." + record.server.id)
                self.lock.lock()
                self.workingConnection = base
                self.libraries = available
                self.selectedLibraryID = PlexLibrary.restoredID(in: available, preferred: preference)
                self.lock.unlock()
                self.setPhase("connected", message: available.isEmpty ? "No music libraries are available on this server." : "Music libraries are ready.")
                completion(.success(available))
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true { self.setFailure(error.localizedDescription) }
                completion(.failure(error))
            }
        }
    }

    func selectLibrary(id: String) throws {
        lock.lock()
        guard let serverID = selectedID, let library = libraries.first(where: { $0.id == id }) else {
            lock.unlock()
            throw PlexServiceError("Choose a music library available on this server.")
        }
        lock.unlock()
        cancelCurrentRequest()
        lock.lock()
        selectedLibraryID = id
        lock.unlock()
        UserDefaults.standard.set(id, forKey: "PlexMusicLibrary." + serverID)
        setPhase("connected", message: "Using " + library.name + ".")
    }

    private func selectedServerAccess() throws -> PlexServerRecord {
        lock.lock()
        let record = selectedID.flatMap { records[$0] }
        lock.unlock()
        guard let record = record else { throw PlexServiceError("Choose a Plex server first.") }
        return record
    }

    private func withConnection<T>(record: PlexServerRecord, _ attempt: (URL) throws -> T) throws -> T {
        lock.lock()
        let working = workingConnection
        lock.unlock()
        let urls = record.connections.map(\.url)
        let ordered = urls.filter { $0 == working } + urls.filter { $0 != working }
        var tried = Set<URL>()
        var messages = [String]()
        for url in ordered where tried.insert(url).inserted {
            do { return try attempt(url) }
            catch let error as PlexServiceError where error.retryOtherConnection {
                if !messages.contains(error.message) { messages.append(error.message) }
            }
        }
        throw PlexServiceError(messages.isEmpty ? "No secure Plex server connection is available." : messages.joined(separator: " "))
    }

    func search(showDate: String, preferredVersion: Int? = nil, allowUnversionedAlbum: Bool = false,
                completion: @escaping (Result<PlexSearchResult, Error>) -> Void) {
        cancelCurrentRequest()
        let record: PlexServerRecord
        let section: PlexLibrary
        do {
            _ = try PlexParser.searchQueries(showDate: showDate, preferredVersion: preferredVersion)
            record = try selectedServerAccess()
            lock.lock()
            let selection = libraries.first { $0.id == selectedLibraryID }
            lock.unlock()
            guard let selection = selection else { throw PlexServiceError("Choose a Plex music library first.") }
            section = selection
        } catch {
            setFailure(error.localizedDescription)
            completion(.failure(error))
            return
        }

        run(phase: "searching", message: "Searching \(section.name)…", perform: { operation in
            try self.withConnection(record: record) { base in
                let token = record.token
                func read(_ path: String, _ query: [URLQueryItem]) throws -> Data {
                    let request = try self.serverRequest(base: base, path: path, query: query, token: token)
                    return try operation.fetch(request, limit: 8 * 1024 * 1024, timeout: 12)
                }
                return try PlexParser.recording(in: section.id, showDate: showDate, preferredVersion: preferredVersion,
                                                allowUnversionedAlbum: allowUnversionedAlbum, serverURL: base,
                                                token: token, read: read)
            }
        }) { result in
            switch result {
            case .success: self.setPhase("connected", message: "Plex recording found in \(section.name).")
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true { self.setFailure(error.localizedDescription) }
            }
            completion(result)
        }
    }

    @discardableResult
    func cancelSearch() -> Bool {
        let canceled = cancelCurrentRequest()
        if canceled { setPhase("connected", message: "Plex search canceled.") }
        return canceled
    }

    func disconnect() throws {
        cancelCurrentRequest()
        UserDefaults.standard.removeObject(forKey: Self.preferredServerKey)
        var removalError: Error?
        do { try credentials.removeValue(for: Self.accountKey) } catch { removalError = error }
        do { try credentials.removeValues(withPrefix: Self.serverKeyPrefix) } catch {
            if removalError == nil { removalError = error }
        }
        lock.lock()
        hasAccount = false
        records.removeAll()
        libraries = []
        selectedID = nil
        selectedLibraryID = nil
        workingConnection = nil
        phase = "disconnected"
        message = ""
        let value = statusLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
        if let removalError = removalError { throw removalError }
    }

    private func run<T>(phase: String, message: String, request: URLRequest, limit: Int,
                        transform: @escaping (Data) throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        run(phase: phase, message: message, perform: { operation in
            try transform(operation.fetch(request, limit: limit))
        }, completion: completion)
    }

    private func run<T>(phase: String, message: String, perform: @escaping (PlexRequestOperation) throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        cancelCurrentRequest()
        lock.lock(); generation += 1; let currentGeneration = generation; self.phase = phase; self.message = message
        let operation = PlexRequestOperation(); self.operation = operation
        cancellationHandler = { completion(.failure(PlexServiceError.canceled)) }
        let value = statusLocked(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
        work.async { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try perform(operation)) }
            catch { result = .failure(error) }
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let current = self.operation === operation && self.generation == currentGeneration
                if current {
                    self.operation = nil
                    self.cancellationHandler = nil
                }
                self.lock.unlock()
                if current { completion(result) }
            }
        }
    }


    @discardableResult
    private func cancelCurrentRequest(notify: Bool = true) -> Bool {
        lock.lock()
        generation += 1
        let current = operation
        let handler = cancellationHandler
        operation = nil
        cancellationHandler = nil
        lock.unlock()
        current?.cancel()
        if notify, let handler = handler { DispatchQueue.main.async(execute: handler) }
        return current != nil
    }

    private func authorizedRequest(url: URL, method: String, token: String?) -> URLRequest {
        precondition(url.scheme == "https" && (url.host == "plex.tv" || url.host == "clients.plex.tv"))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        applyHeaders(to: &request, token: token)
        return request
    }

    private func serverRequest(base: URL, path: String, query: [URLQueryItem], token: String) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PlexServiceError("The Plex server request is invalid.")
        }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw PlexServiceError("The Plex server request is invalid.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        applyHeaders(to: &request, token: token)
        return request
    }

    private func applyHeaders(to request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("iPlex", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        request.setValue(platform, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("iPlex", forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Plex-Platform-Version")
        if let token = token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    private func setPhase(_ phase: String, message: String) {
        lock.lock(); self.phase = phase; self.message = message; let value = statusLocked(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
    }

    private func setFailure(_ message: String) { setPhase("failed", message: message) }

    private func statusLocked() -> PlexStatus {
        let server = selectedID.flatMap { records[$0]?.server }
        let library = libraries.first { $0.id == selectedLibraryID }
        return PlexStatus(phase: phase,
                          connected: phase != "disconnected" && hasAccount,
                          serverCount: records.count,
                          selectedServerID: server?.id,
                          selectedServerName: server?.name,
                          selectedLibraryID: library?.id,
                          selectedLibraryName: library?.name,
                          message: message)
    }

    private static func persistentClientIdentifier() -> String {
        let key = "PlexClientIdentifier"
        if let value = UserDefaults.standard.string(forKey: key), value.count >= 8 { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

enum MusicKind: String, CaseIterable {
    case albums = "Albums"
    case artists = "Artists"

    case genres = "Genres"
    case tracks = "Tracks"
    case playlists = "Playlists"

    var plexName: String {
        switch self {
        case .albums: "album"
        case .artists: "artist"
        case .genres: "genre"
        case .tracks: "track"
        case .playlists: "playlist"
        }
    }

    var plexType: String {
        switch self {
        case .artists: "8"
        case .tracks: "10"
        case .playlists: "15"
        case .albums, .genres: "9"
        }
    }

    var symbol: String {
        switch self {
        case .albums: "opticaldisc"
        case .artists: "person.2"
        case .genres: "tag"
        case .tracks: "music.note"
        case .playlists: "music.note.list"
        }
    }

    var isGroup: Bool { self == .artists || self == .genres }

    var playLabel: String {
        switch self {
        case .playlists: "Play Playlist"
        case .tracks: "Play Track"
        default: "Play Album"
        }
    }
}

struct MusicEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
    let genres: [String]
    let artworkPath: String?
    let kind: MusicKind
}

extension PlexParser {
    static func musicEntries(_ data: Data, kind: MusicKind, section: String) throws
        -> (items: [MusicEntry], rawCount: Int, totalSize: Int?) {
        let container = try metadataContainer(data)
        let rows = kind == .genres ? (container["Directory"] as? [[String: Any]] ?? []) :
            try metadataRows(container, sectionID: kind == .playlists ? nil : section)
        var seen = Set<String>()
        let items = rows.compactMap { row -> MusicEntry? in
            let id: String?
            if kind == .genres {
                let key = row["key"] as? String ?? ""
                let path = URLComponents(string: key)
                let genre = path?.path == "/library/sections/\(section)/all"
                    ? path?.queryItems?.first { $0.name == "genre" }?.value : nil
                id = numericIdentifier(genre ?? row["key"])
            } else {
                guard row["type"] as? String == kind.plexName,
                      kind != .playlists || row["playlistType"] as? String == "audio" else { return nil }
                id = numericIdentifier(row["ratingKey"])
            }
            guard let id, seen.insert(id).inserted,
                  let title = string(row["title"], maximum: 300) else { return nil }
            let artist = row[kind == .tracks ? "grandparentTitle" : "parentTitle"]
            let artwork = [row["thumb"], row["parentThumb"], row["composite"]]
                .lazy.compactMap { musicArtworkPath($0 as? String) }.first
            return MusicEntry(id: id, title: title, artist: string(artist, maximum: 300) ?? "",
                              year: integer(row["year"]),
                              genres: (row["Genre"] as? [[String: Any]] ?? []).prefix(8).compactMap { string($0["tag"], maximum: 80) },
                              artworkPath: artwork, kind: kind)
        }
        return (items, rows.count, integer(container["totalSize"]))
    }

    static func musicArtworkPath(_ value: String?) -> String? {
        guard let value, value.count < 180,
              value.range(of: #"^(?:/library/metadata/[0-9]+/thumb|/playlists/[0-9]+/composite)(?:/[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static let musicPlaylistLimit = 10_000

    static func musicTrackPage(_ data: Data, entry: MusicEntry, section: String, base: URL, token: String, offset: Int = 0)
        throws -> (tracks: [LiveTrack], rawCount: Int, totalSize: Int?) {
        let container = try metadataContainer(data)
        let rows = try metadataRows(container, sectionID: entry.kind == .playlists ? nil : section)
        if entry.kind == .albums && rows.count > 250 {
            throw PlexServiceError("This album has too many tracks for the current player.")
        }
        var seen = Set<String>()
        var tracks = [(disc: Int, index: Int, title: String, duration: Double?, url: URL)]()
        for (position, row) in rows.enumerated() {
            guard row["type"] as? String == "track", let id = numericIdentifier(row["ratingKey"]),
                  entry.kind != .albums || row["parentRatingKey"] == nil || numericIdentifier(row["parentRatingKey"]) == entry.id,
                  entry.kind != .tracks || id == entry.id,
                  entry.kind == .playlists || seen.insert(id).inserted,
                  let title = string(row["title"], maximum: 300),
                  let media = row["Media"] as? [[String: Any]], media.count <= 16 else { continue }
            let options = media.flatMap { Array(($0["Part"] as? [[String: Any]] ?? []).prefix(16)) }
            let url = options.lazy.compactMap { part -> URL? in
                guard let path = part["key"] as? String,
                      supportedFormats.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
                return try? playbackURL(base: base, partPath: path, token: token)
            }.first
            guard let url else { continue }
            tracks.append((integer(row["parentIndex"]) ?? 1, integer(row["index"]) ?? (position + 1),
                           title, milliseconds(row["duration"]), url))
        }
        if entry.kind == .albums {
            tracks = tracks.enumerated().sorted {
                ($0.element.disc, $0.element.index, $0.offset) < ($1.element.disc, $1.element.index, $1.offset)
            }.map(\.element)
        }
        return (tracks.enumerated().map { index, row in
            LiveTrack(number: offset + index + 1, title: row.title, duration: row.duration, url: row.url)
        }, rows.count, integer(container["totalSize"]))
    }
}

extension PlexService {
    func musicEntries(kind: MusicKind, query: String, offset: Int, limit: Int, group: MusicEntry? = nil,
                      completion: @escaping (Result<(items: [MusicEntry], rawCount: Int, hasMore: Bool), Error>) -> Void) {
        inMusicLibrary(phase: "Browsing library", completion: completion) { base, section, token, operation in
            var parameters: [URLQueryItem] = [
                .init(name: "X-Plex-Container-Start", value: String(offset)),
                .init(name: "X-Plex-Container-Size", value: String(limit))
            ]
            let path: String
            let localPaging = kind == .genres || kind == .playlists
            if let group, group.kind == .artists {
                path = "/library/metadata/\(group.id)/children"
            } else if kind == .genres {
                path = "/library/sections/\(section)/genre"
                parameters = [.init(name: "type", value: kind.plexType)]
            } else if kind == .playlists {
                path = "/playlists"
                parameters = [.init(name: "type", value: kind.plexType),
                              .init(name: "sectionID", value: section),
                              .init(name: "playlistType", value: "audio")]
            } else {
                path = "/library/sections/\(section)/all"
                parameters.append(.init(name: "type", value: kind.plexType))
                parameters.append(.init(name: "sort", value: "titleSort:asc"))
                if let group, group.kind == .genres { parameters.append(.init(name: "genre", value: group.id)) }
                if !query.isEmpty { parameters.append(.init(name: "title", value: String(query.prefix(120)))) }
            }
            let data = try operation.fetch(self.serverRequest(base: base, path: path, query: parameters, token: token),
                                           limit: 8 * 1024 * 1024)
            let page = try PlexParser.musicEntries(data, kind: kind, section: section)
            if localPaging {
                let matches = page.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let items = Array(matches.dropFirst(offset).prefix(limit))
                return (items, items.count, offset + items.count < matches.count)
            }
            return (page.items, page.rawCount,
                    page.totalSize.map { offset + page.rawCount < $0 } ?? (page.rawCount >= limit))
        }
    }

    func musicTracks(entry: MusicEntry, completion: @escaping (Result<[LiveTrack], Error>) -> Void) {
        guard !entry.kind.isGroup, !entry.id.isEmpty, entry.id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            completion(.failure(PlexServiceError("The library item identifier is invalid.")))
            return
        }
        inMusicLibrary(phase: "Loading tracks", completion: completion) { base, section, token, operation in
            let playlist = entry.kind == .playlists
            let path = playlist ? "/playlists/\(entry.id)/items" :
                "/library/metadata/\(entry.id)" + (entry.kind == .albums ? "/children" : "")
            let batch = 200
            var start = 0
            var tracks: [LiveTrack] = []
            var hasMore: Bool
            repeat {
                let query: [URLQueryItem] = playlist ? [
                    .init(name: "X-Plex-Container-Start", value: String(start)),
                    .init(name: "X-Plex-Container-Size", value: String(batch))
                ] : []
                let endpoint = try self.serverRequest(base: base, path: path, query: query, token: token)
                let page = try PlexParser.musicTrackPage(operation.fetch(endpoint, limit: 8 * 1024 * 1024),
                                                         entry: entry, section: section, base: base, token: token,
                                                         offset: tracks.count)
                tracks.append(contentsOf: page.tracks)
                start += page.rawCount
                hasMore = playlist && page.rawCount > 0 &&
                    (page.totalSize.map { start < $0 } ?? (page.rawCount >= batch))
                if playlist && (start > PlexParser.musicPlaylistLimit || (hasMore && start >= PlexParser.musicPlaylistLimit)) {
                    throw PlexServiceError("This playlist exceeds the 10,000-track playback limit.")
                }
            } while hasMore
            guard !tracks.isEmpty else { throw PlexServiceError("This item has no tracks the player can stream directly.") }
            return try PlexParser.validatedPlaybackTracks(tracks, maximum: playlist ? PlexParser.musicPlaylistLimit : 250)
        }
    }

    func musicArtwork(path: String, completion: @escaping (Data?) -> Void) -> (() -> Void)? {
        guard let path = PlexParser.musicArtworkPath(path), let record = try? selectedServerAccess() else {
            completion(nil)
            return nil
        }
        let operation = PlexRequestOperation()
        let selection = status
        Self.artworkQueue.addOperation { [weak self] in
            guard let self else { return }
            let cached = AlbumCoverCache.location(server: selection.selectedServerID ?? "",
                                                  library: selection.selectedLibraryID ?? "", path: path)
            let data = (try? Data(contentsOf: cached)) ?? (try? self.withConnection(record: record) { base in
                try self.fetchMusicArtwork(path, base: base, token: record.token, operation: operation)
            })
            DispatchQueue.main.async { completion(data) }
        }
        return { operation.cancel() }
    }

    func cacheLibraryArtwork(progress: @escaping (Int, Int) -> Void,
                          completion: @escaping (Result<(Int, Int), Error>) -> Void) -> (() -> Void)? {
        let selection = status
        guard let server = selection.selectedServerID, let section = selection.selectedLibraryID,
              let record = try? selectedServerAccess() else {
            completion(.failure(PlexServiceError("Choose a Plex music library first.")))
            return nil
        }
        let operation = PlexRequestOperation()
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                var saved = 0, skipped = 0
                for kind in [MusicKind.albums, .artists] {
                    var offset = 0
                    var visited = Set<String>()
                    while true {
                        let page = try self.withConnection(record: record) { base in
                            let query: [URLQueryItem] = [
                                .init(name: "type", value: kind.plexType), .init(name: "sort", value: "titleSort:asc"),
                                .init(name: "X-Plex-Container-Start", value: String(offset)),
                                .init(name: "X-Plex-Container-Size", value: "60")
                            ]
                            let request = try self.serverRequest(base: base, path: "/library/sections/\(section)/all",
                                                                 query: query, token: record.token)
                            return try PlexParser.musicEntries(operation.fetch(request, limit: 8 * 1024 * 1024),
                                                               kind: kind, section: section)
                        }
                        if page.rawCount == 0 { break }
                        let fresh = page.items.filter { visited.insert($0.id).inserted }
                        guard !fresh.isEmpty else { throw PlexServiceError("Plex stopped advancing through the \(kind.rawValue.lowercased()) list.") }
                        for item in fresh {
                            try operation.checkCancellation()
                            do {
                                guard let path = item.artworkPath else { throw PlexServiceError("No artwork.") }
                                let target = AlbumCoverCache.location(server: server, library: section, path: path)
                                if !FileManager.default.fileExists(atPath: target.path) {
                                    let bytes = try self.withConnection(record: record) { base in
                                        try self.fetchMusicArtwork(path, base: base, token: record.token, operation: operation)
                                    }
                                    try operation.checkCancellation()
                                    try AlbumCoverCache.save(bytes, to: target)
                                }
                                saved += 1
                            } catch {
                                try operation.checkCancellation()
                                skipped += 1
                            }
                            if (saved + skipped).isMultiple(of: 10) {
                                let counts = (saved, skipped)
                                DispatchQueue.main.async { progress(counts.0, counts.1) }
                            }
                        }
                        offset += page.rawCount
                    }
                }
                try operation.checkCancellation()
                return (saved, skipped)
            }
            DispatchQueue.main.async { completion(result) }
        }
        return { operation.cancel() }
    }

    private func fetchMusicArtwork(_ path: String, base: URL, token: String, operation: PlexRequestOperation) throws -> Data {
        var request = try serverRequest(base: base, path: path, query: [], token: token)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try operation.fetch(request, limit: 8 * 1024 * 1024, timeout: 10)
    }

    private static let artworkQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()

    private func inMusicLibrary<T>(phase: String, completion: @escaping (Result<T, Error>) -> Void,
                                   _ body: @escaping (URL, String, String, PlexRequestOperation) throws -> T) {
        do {
            let record = try selectedServerAccess()
            lock.lock()
            let section = selectedLibraryID
            lock.unlock()
            guard let section else { throw PlexServiceError("Choose a Plex music library first.") }
            run(phase: "browsing", message: phase + "…", perform: { operation in
                try self.withConnection(record: record) { base in try body(base, section, record.token, operation) }
            }, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }
}
