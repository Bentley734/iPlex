import ImageIO
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var libraries: [PlexLibrary] = []
    @Published private(set) var serverID = ""
    @Published private(set) var libraryID = ""
    @Published private(set) var entries: [MusicEntry] = []
    @Published private(set) var selectedArtist: MusicEntry?
    @Published private(set) var selectedAlbum: MusicEntry?
    @Published private(set) var tracks: [LiveTrack] = []
    @Published private(set) var playingAlbum: MusicEntry?
    @Published private(set) var playingTracks: [LiveTrack] = []
    @Published private(set) var busy = false
    @Published private(set) var more = false
    @Published private(set) var signInURL: URL?
    @Published private(set) var linkCode: String?
    @Published private(set) var state = PlayerState()
    @Published private(set) var playbackVolume = 1.0
    @Published private(set) var playingArtwork: MusicImage?
    @Published private(set) var equalizer = PlaybackEQSettings.flat
    @Published private(set) var equalizerAvailable: Bool?
    @Published private(set) var cachingCovers = false
    @Published private(set) var coverCacheStatus = ""
    @Published var message: String?
    @Published var kind: MusicKind = .albums
    @Published var query = ""

    private let service = PlexService(version: "0.1")
    let player = PlayerController()
    private var operation: Task<Void, Never>?
    private var offset = 0
    private let artwork = NSCache<NSString, MusicImage>()
    private var artworkRequests = [ArtworkKey: ArtworkRequest]()
    private var artworkCollection = UUID()
    private var cancelCoverCache: (() -> Void)?
    private var cacheGeneration = UUID()

    struct ArtworkKey: Hashable {
        let collection: UUID
        let path: String
    }

    private final class ArtworkRequest {
        var cancel: (() -> Void)?
        var completions = [(MusicImage?) -> Void]()
    }

    struct PlayerState {
        var title = ""
        var elapsed = 0.0
        var duration = 0.0
        var status = "idle"
        var playing = false
        var previous = false
        var next = false
        var index: Int?
        var message = ""
        var nextTitle: String?
    }

    init() {
        artwork.countLimit = 100
        connected = service.status.connected
        let defaults = UserDefaults.standard
        if let values = defaults.array(forKey: "PlaybackEqualizer") as? [Double], values.count == 3 {
            equalizer = PlaybackEQSettings(bass: values[0], mid: values[1], treble: values[2])
            player.setEqualizer(equalizer)
        }
        player.onEqualizerAvailability = { [weak self] in self?.equalizerAvailable = $0 }
        player.onStateChange = { [weak self] value in
            self?.state = PlayerState(title: value["title"] as? String ?? "", elapsed: value["elapsed"] as? Double ?? 0,
                                      duration: value["duration"] as? Double ?? 0, status: value["status"] as? String ?? "idle",
                                      playing: value["playing"] as? Bool ?? false, previous: value["canPrevious"] as? Bool ?? false,
                                      next: value["canNext"] as? Bool ?? false, index: value["trackIndex"] as? Int,
                                      message: value["message"] as? String ?? "", nextTitle: value["nextTitle"] as? String)
        }
    }

    func restore() {
        guard connected, servers.isEmpty, !busy else { return }
        perform { try await self.findServers() }
    }

    func signIn() {
        perform {
            #if os(tvOS)
            let method = PlexSignInMethod.linkCode
            #else
            let method = PlexSignInMethod.browser
            #endif
            let session = try await self.request { self.service.beginConnection(method: method, completion: $0) }
            try Task.checkCancellation()
            self.signInURL = session.authorizationURL
            #if os(tvOS)
            self.linkCode = session.code
            #else
            MusicPlatform.openSignIn(session.authorizationURL)
            #endif
            defer { self.signInURL = nil; self.linkCode = nil }
            let deadline = Date().addingTimeInterval(TimeInterval(min(session.expiresIn, 900)))
            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                let poll = try await self.request { self.service.pollConnection(pinID: session.pinID, completion: $0) }
                try Task.checkCancellation()
                if poll == .connected {
                    self.connected = true
                    try await self.findServers()
                    return
                }
            }
            throw PlexServiceError.expiredPIN
        }
    }

    func cancel() {
        operation?.cancel()
        busy = false
        _ = service.cancelSearch()
    }

    private func findServers() async throws {
        servers = try await request(service.refreshServers)
        try Task.checkCancellation()
        serverID = service.status.selectedServerID ?? ""
        if serverID.isEmpty, let only = servers.onlyElement {
            try service.selectServer(id: only.id)
            serverID = only.id
        }
        if !serverID.isEmpty { try await findLibraries() }
    }

    func chooseServer(_ id: String) {
        guard !id.isEmpty, id != serverID else { return }
        perform {
            try self.service.selectServer(id: id)
            self.serverID = id
            self.libraries = []
            self.libraryID = ""
            self.resetLibrary()
            try await self.findLibraries()
        }
    }

    private func findLibraries() async throws {
        libraries = try await request(service.refreshLibraries)
        try Task.checkCancellation()
        libraryID = service.status.selectedLibraryID ?? ""
        if libraryID.isEmpty, let only = libraries.onlyElement {
            try service.selectLibrary(id: only.id)
            libraryID = only.id
        }
        if !libraryID.isEmpty { try await loadEntries(append: false) }
    }

    func chooseLibrary(_ id: String) {
        guard !id.isEmpty, id != libraryID else { return }
        perform {
            try self.service.selectLibrary(id: id)
            self.libraryID = id
            self.resetLibrary()
            try await self.loadEntries(append: false)
        }
    }

    func disconnect() {
        cancel()
        do {
            try service.disconnect()
            connected = false
            servers = []
            libraries = []
            serverID = ""
            libraryID = ""
            resetLibrary()
        } catch { message = error.localizedDescription }
    }

    private func resetLibrary() {
        stopCachingCovers()
        coverCacheStatus = ""
        selectedArtist = nil
        selectedAlbum = nil
        entries = []
        tracks = []
        playingAlbum = nil
        playingTracks = []
        playingArtwork = nil
        offset = 0
        more = false
        player.stop()
        artworkCollection = UUID()
        let canceledRequests = artworkRequests.values
        artworkRequests.removeAll()
        artwork.removeAllObjects()
        for request in canceledRequests {
            request.cancel?()
            request.completions.forEach { $0(nil) }
        }
    }

    func browse() {
        guard !libraryID.isEmpty else { return }
        selectedArtist = nil
        selectedAlbum = nil
        tracks = []
        perform { try await self.loadEntries(append: false) }
    }

    func loadMore() {
        guard more, !busy else { return }
        perform { try await self.loadEntries(append: true) }
    }

    func open(_ entry: MusicEntry) {
        if entry.kind == .artists {
            selectedArtist = entry
            selectedAlbum = nil
            perform { try await self.loadEntries(append: false) }
        } else {
            selectedAlbum = entry
            tracks = []
            perform {
                let found = try await self.request { self.service.musicTracks(album: entry, completion: $0) }
                try Task.checkCancellation()
                self.tracks = found
            }
        }
    }

    func closeAlbum() {
        cancel()
        selectedAlbum = nil
        tracks = []
    }

    func play(at index: Int) {
        guard let album = selectedAlbum, tracks.indices.contains(index) else { return }
        let key = artworkKey(for: album)
        playingAlbum = album
        playingTracks = tracks
        playingArtwork = key.flatMap { artwork.object(forKey: $0.path as NSString) }
        player.loadRemoteTracks(tracks, collection: album.title, artist: album.artist, artwork: playingArtwork, startTrack: index)
        if playingArtwork == nil, let key {
            fetchImage(for: key) { [weak self] image in
                guard let self, let image, let playingAlbum = self.playingAlbum,
                      self.artworkKey(for: playingAlbum) == key else { return }
                self.playingArtwork = image
                self.player.updateAlbumArtwork(image)
            }
        }
    }

    func artworkKey(for item: MusicEntry) -> ArtworkKey? {
        item.artworkPath.map { ArtworkKey(collection: artworkCollection, path: $0) }
    }

    func changePlaybackVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        playbackVolume = min(1, max(0, volume))
        player.setPlaybackVolume(playbackVolume)
    }

    func image(for key: ArtworkKey) async -> MusicImage? {
        await withCheckedContinuation { continuation in
            fetchImage(for: key) { continuation.resume(returning: $0) }
        }
    }

    private func fetchImage(for key: ArtworkKey, completion: @escaping (MusicImage?) -> Void) {
        guard key.collection == artworkCollection else { return completion(nil) }
        let path = key.path as NSString
        if let cached = artwork.object(forKey: path) { return completion(cached) }
        if let request = artworkRequests[key] {
            request.completions.append(completion)
            return
        }
        let request = ArtworkRequest()
        request.completions.append(completion)
        artworkRequests[key] = request
        request.cancel = service.musicArtwork(path: key.path) { [weak self] data in
            guard let self, let completed = self.artworkRequests.removeValue(forKey: key) else { return }
            let cover = data.flatMap(AlbumCoverCache.thumbnail).map(MusicPlatform.image)
            if let cover { self.artwork.setObject(cover, forKey: path) }
            completed.completions.forEach { $0(cover) }
        }
    }

    func updateEqualizer(_ settings: PlaybackEQSettings) {
        equalizer = settings
        player.setEqualizer(settings)
        UserDefaults.standard.set([settings.bass, settings.mid, settings.treble], forKey: "PlaybackEqualizer")
    }

    func cacheLibraryArtwork() {
        guard !libraryID.isEmpty, !cachingCovers else { return }
        let generation = UUID()
        cacheGeneration = generation
        cachingCovers = true
        coverCacheStatus = "Checking albums and artists…"
        cancelCoverCache = service.cacheLibraryArtwork { [weak self] saved, skipped in
            guard let self, self.cacheGeneration == generation else { return }
            self.coverCacheStatus = Self.cacheSummary(saved: saved, skipped: skipped)
        } completion: { [weak self] result in
            guard let self, self.cacheGeneration == generation else { return }
            self.cancelCoverCache = nil
            self.cachingCovers = false
            switch result {
            case let .success((saved, skipped)):
                self.coverCacheStatus = Self.cacheSummary(saved: saved, skipped: skipped)
            case let .failure(error):
                self.coverCacheStatus = error.localizedDescription
            }
        }
    }

    func stopCachingCovers() {
        guard cachingCovers else { return }
        cacheGeneration = UUID()
        cancelCoverCache?()
        cancelCoverCache = nil
        cachingCovers = false
        coverCacheStatus = "Canceled. Downloaded artwork were kept."
    }

    private static func cacheSummary(saved: Int, skipped: Int) -> String {
        let text = "\(saved) \(saved == 1 ? "image" : "images") cached"
        return skipped == 0 ? text : text + " · \(skipped) unavailable"
    }

    private func loadEntries(append: Bool) async throws {
        let start = append ? offset : 0
        let artist = selectedArtist
        let result = try await request {
            service.musicEntries(kind: artist == nil ? kind : .albums, query: query, offset: start,
                                 artist: artist, completion: $0)
        }
        try Task.checkCancellation()
        let existing = append ? entries : []
        var seen = Set(existing.map(\.id))
        let unique = result.items.filter { seen.insert($0.id).inserted }
        entries = existing + unique
        offset = start + result.rawCount
        more = result.rawCount >= 60 && !unique.isEmpty
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        cancel()
        message = nil
        busy = true
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do { try await action() }
            catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func request<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
