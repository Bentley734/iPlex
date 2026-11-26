import ImageIO
import SwiftUI

enum LibraryPageSize: String, CaseIterable, Identifiable {
    static let preferenceKey = "LibraryPageSize"
    case compact = "30", standard = "60", expanded = "120", all = "all"

    var id: Self { self }
    var label: String { self == .all ? "All" : rawValue }
    var batch: Int { Int(rawValue) ?? 120 }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var libraries: [PlexLibrary] = []
    @Published private(set) var serverID = ""
    @Published private(set) var libraryID = ""
    @Published private(set) var pins: [MusicEntry] = []
    @Published private(set) var entries: [MusicEntry] = []
    @Published private(set) var selectedGroup: MusicEntry?
    @Published private(set) var selectedDetail: MusicEntry?
    @Published private(set) var tracks: [LiveTrack] = []
    @Published private(set) var playingAlbum: MusicEntry?
    @Published private(set) var playingTracks: [LiveTrack] = []
    @Published private(set) var busy = false
    @Published private(set) var reconnecting = false
    @Published private(set) var more = false
    @Published private(set) var signInURL: URL?
    @Published private(set) var linkCode: String?
    @Published private(set) var state = PlayerState()
    @Published private(set) var playbackVolume = 1.0
    @Published private(set) var playingArtwork: MusicImage? {
        didSet { playingPalette = playingArtwork.flatMap(ArtworkPalette.init) }
    }
    @Published private(set) var playingPalette: ArtworkPalette?
    @Published private(set) var equalizer = PlaybackEQSettings.flat
    @Published private(set) var equalizerAvailable: Bool?
    @Published private(set) var cachingCovers = false
    @Published private(set) var coverCacheStatus = ""
    @Published var message: String?
    @Published private(set) var kind: MusicKind = .albums
    @Published private(set) var visibleKinds = MusicKind.allCases
    @Published var query = ""

    let service = PlexService(version: "0.1")
    let player = PlayerController()
    private var operation: Task<Void, Never>?
    private var launchSnapshot: LibrarySnapshot?
    private static let snapshotKey = "LastMusicLibrary"

    private struct LibrarySnapshot: Codable {
        var server: String
        var library: String
        var servers: [PlexServer]
        var libraries: [PlexLibrary]
        var listings: [MusicKind: [MusicEntry]] = [:]
    }
    private var offset = 0
    private var listingQuery = ""
    private var refreshAfterAlbum = false
    private let artwork = NSCache<NSString, MusicImage>()
    private var artworkRequests = [ArtworkKey: ArtworkRequest]()
    private var artworkCollection = UUID()
    private var playingArtworkKey: ArtworkKey?
    private var originalQueueIDs = Set<UUID>()
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
        if let saved = defaults.stringArray(forKey: "VisibleMusicSections") {
            let enabled = MusicKind.allCases.filter { saved.contains($0.rawValue) }
            if let first = enabled.first {
                visibleKinds = enabled
                kind = first
            }
        }
        if let saved = service.rememberedMusicSelection {
            serverID = saved.server
            libraryID = saved.library
            if let data = defaults.data(forKey: Self.snapshotKey),
               let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data),
               snapshot.server == serverID, snapshot.library == libraryID {
                launchSnapshot = snapshot
                servers = snapshot.servers
                libraries = snapshot.libraries
                entries = snapshot.listings[kind] ?? []
            }
            loadPins()
            reconnecting = true
        }
        if let values = defaults.array(forKey: "PlaybackEqualizer") as? [Double], values.count == 3 {
            equalizer = PlaybackEQSettings(bass: values[0], mid: values[1], treble: values[2])
            player.setEqualizer(equalizer)
        }
        player.onQueueChange = { [weak self] queue in
            self?.playingTracks = queue
            if queue.isEmpty {
                self?.playingAlbum = nil
                self?.originalQueueIDs.removeAll()
                self?.playingArtwork = nil
                self?.playingArtworkKey = nil
            }
        }
        player.onEqualizerAvailability = { [weak self] in self?.equalizerAvailable = $0 }
        player.onStateChange = { [weak self] value in
            self?.state = PlayerState(title: value["title"] as? String ?? "", elapsed: value["elapsed"] as? Double ?? 0,
                                      duration: value["duration"] as? Double ?? 0, status: value["status"] as? String ?? "idle",
                                      playing: value["playing"] as? Bool ?? false, previous: value["canPrevious"] as? Bool ?? false,
                                      next: value["canNext"] as? Bool ?? false, index: value["trackIndex"] as? Int,
                                      message: value["message"] as? String ?? "", nextTitle: value["nextTitle"] as? String)
            if let index = value["trackIndex"] as? Int { self?.refreshPlayingArtwork(at: index) }
        }
    }

    func restore() {
        guard connected, (reconnecting || servers.isEmpty || service.status.selectedLibraryID == nil), !busy else { return }
        perform {
            defer {
                if !Task.isCancelled, self.reconnecting {
                    self.reconnecting = false
                    self.invalidateArtwork()
                }
            }
            try await self.findServers()
        }
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

    func retryLibrary() {
        if service.status.selectedLibraryID == nil { restore() }
        else { browse() }
    }

    func cancel() {
        operation?.cancel()
        busy = false
        _ = service.cancelSearch()
    }

    private func findServers() async throws {
        servers = try await request(service.refreshServers)
        try Task.checkCancellation()
        let discovered = service.status.selectedServerID ?? ""
        if serverID != discovered {
            serverID = discovered
            libraryID = ""
            libraries = []
            resetLibrary()
        }
        if serverID.isEmpty, let only = servers.onlyElement {
            try service.selectServer(id: only.id)
            serverID = only.id
        }
        if !serverID.isEmpty { try await findLibraries() }
    }

    func chooseServer(_ id: String) {
        guard !reconnecting, !id.isEmpty, id != serverID else { return }
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
        let discovered = service.status.selectedLibraryID ?? ""
        if libraryID != discovered {
            libraryID = discovered
            resetLibrary()
        }
        if libraryID.isEmpty, let only = libraries.onlyElement {
            try service.selectLibrary(id: only.id)
            libraryID = only.id
        }
        loadPins()
        if !libraryID.isEmpty { try await loadEntries(append: false) }
        else {
            launchSnapshot = nil
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        }
    }

    func chooseLibrary(_ id: String) {
        guard !reconnecting, !id.isEmpty, id != libraryID else { return }
        perform {
            try self.service.selectLibrary(id: id)
            self.libraryID = id
            self.resetLibrary()
            self.loadPins()
            try await self.loadEntries(append: false)
        }
    }

    func disconnect() {
        cancel()
        do {
            try service.disconnect()
            connected = false
            reconnecting = false
            launchSnapshot = nil
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
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
        pins = []
        selectedGroup = nil
        selectedDetail = nil
        entries = []
        tracks = []
        playingAlbum = nil
        playingTracks = []
        playingArtworkKey = nil
        playingArtwork = nil
        offset = 0
        listingQuery = ""
        refreshAfterAlbum = false
        more = false
        player.stop()
        invalidateArtwork()
    }

    private func invalidateArtwork() {
        artworkCollection = UUID()
        let canceledRequests = artworkRequests.values
        artworkRequests.removeAll()
        artwork.removeAllObjects()
        for request in canceledRequests {
            request.cancel?()
            request.completions.forEach { $0(nil) }
        }
    }

    func selectKind(_ section: MusicKind) {
        guard visibleKinds.contains(section) else { return }
        kind = section
        if reconnecting { entries = launchSnapshot?.listings[kind] ?? [] }
        else { browse() }
    }

    func setVisibility(_ section: MusicKind, visible: Bool) {
        let enabled = MusicKind.allCases.filter {
            $0 == section ? visible : visibleKinds.contains($0)
        }
        guard let first = enabled.first, enabled != visibleKinds else { return }
        visibleKinds = enabled
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "VisibleMusicSections")
        if !enabled.contains(kind) { selectKind(first) }
    }

    func browse() {
        guard !reconnecting, !libraryID.isEmpty else { return }
        refreshAfterAlbum = false
        selectedGroup = nil
        selectedDetail = nil
        tracks = []
        perform { try await self.loadEntries(append: false) }
    }

    func refreshPageSize() {
        guard !reconnecting, !libraryID.isEmpty else { return }
        if selectedDetail == nil { perform { try await self.loadEntries(append: false) } }
        else { refreshAfterAlbum = true }
    }

    func loadMore() {
        guard more, !busy else { return }
        perform { try await self.loadEntries(append: true) }
    }

    private var pinPreference: String? {
        guard !serverID.isEmpty, !libraryID.isEmpty else { return nil }
        return "PlexPins.\(serverID).\(libraryID)"
    }

    private func loadPins() {
        pins = pinPreference.flatMap(UserDefaults.standard.data(forKey:))
            .flatMap { try? JSONDecoder().decode([MusicEntry].self, from: $0) } ?? []
    }

    func isPinned(_ entry: MusicEntry) -> Bool {
        pins.contains { $0.id == entry.id && $0.kind == entry.kind }
    }

    func togglePin(_ entry: MusicEntry) {
        guard let pinPreference, entry.kind.canPin else { return }
        if isPinned(entry) {
            pins.removeAll { $0.id == entry.id && $0.kind == entry.kind }
        } else {
            pins.append(entry)
        }
        if let data = try? JSONEncoder().encode(pins) { UserDefaults.standard.set(data, forKey: pinPreference) }
    }

    func lyrics(for track: LiveTrack) async throws -> [MusicLyricLine] {
        guard let id = track.plexID else { return [] }
        let text: String? = try await request { service.musicLyrics(trackID: id, completion: $0) }
        try Task.checkCancellation()
        return text.map(MusicLyricLine.parse) ?? []
    }

    var currentTrack: LiveTrack? {
        guard let index = state.index, playingTracks.indices.contains(index) else { return nil }
        return playingTracks[index]
    }

    func open(_ entry: MusicEntry) {
        guard !reconnecting else { return }
        if entry.kind.isGroup {
            selectedGroup = entry
            selectedDetail = nil
            perform { try await self.loadEntries(append: false) }
        } else {
            selectedDetail = entry
            tracks = []
            perform {
                let found = try await self.request { self.service.musicTracks(entry: entry, completion: $0) }
                try Task.checkCancellation()
                self.tracks = found
            }
        }
    }

    func closeDetail() {
        cancel()
        selectedDetail = nil
        tracks = []
        if refreshAfterAlbum {
            refreshAfterAlbum = false
            refreshPageSize()
        }
    }

    func previewAlbumTracks(_ entry: MusicEntry) async throws -> [LiveTrack] {
        guard !reconnecting, entry.kind == .albums else { return [] }
        let collection = artworkCollection
        let result = try await request { service.musicTracks(entry: entry, inBackground: true, completion: $0) }
        try Task.checkCancellation()
        guard collection == artworkCollection else { throw CancellationError() }
        return result
    }

    func play(_ entry: MusicEntry, albumTracks: [LiveTrack], at index: Int) {
        guard !reconnecting, albumTracks.indices.contains(index) else { return }
        startQueue(albumTracks, entry: entry, index: index, autoplay: true)
    }

    func playLibraryTrack(_ entry: MusicEntry) {
        guard !reconnecting, entry.kind == .tracks else { return }
        perform {
            let result = try await self.request { self.service.musicTracks(entry: entry, completion: $0) }
            try Task.checkCancellation()
            self.play(entry, albumTracks: result, at: 0)
        }
    }

    func play(at index: Int) {
        guard let album = selectedDetail, tracks.indices.contains(index) else { return }
        startQueue(tracks, entry: album, index: index, autoplay: true)
    }

    func enqueue(_ entry: MusicEntry, track: LiveTrack? = nil, playNext: Bool) {
        guard !reconnecting else { return }
        if let track {
            insertIntoQueue([track], entry: entry, playNext: playNext)
        } else if entry == selectedDetail, !tracks.isEmpty {
            insertIntoQueue(tracks, entry: entry, playNext: playNext)
        } else if !entry.kind.isGroup, !busy {
            perform {
                let additions = try await self.request { self.service.musicTracks(entry: entry, completion: $0) }
                try Task.checkCancellation()
                self.insertIntoQueue(additions, entry: entry, playNext: playNext)
            }
        }
    }

    private func insertIntoQueue(_ additions: [LiveTrack], entry: MusicEntry, playNext: Bool) {
        guard !additions.isEmpty else { return }
        if playingTracks.isEmpty || state.status == "finished" {
            startQueue(additions, entry: entry, index: 0, autoplay: playNext)
        } else if playingTracks.count + additions.count <= PlexParser.musicPlaylistLimit {
            player.enqueue(additions, playNext: playNext)
        } else {
            message = "The playback queue can hold up to 10,000 tracks."
            return
        }
        message = playNext ? "Added to Play Next." : "Added to the queue."
    }

    var popularTrackIDs: Set<UUID> {
        guard selectedDetail?.kind == .albums else { return [] }
        let ranked = tracks.filter { $0.ratingCount > 0 }.sorted { $0.ratingCount > $1.ratingCount }
        guard let highest = ranked.first?.ratingCount else { return [] }
        return Set(ranked.prefix(min(3, max(1, tracks.count / 4)))
            .filter { Double($0.ratingCount) >= Double(highest) * 0.25 }.map(\.id))
    }

    private func startQueue(_ tracks: [LiveTrack], entry album: MusicEntry, index: Int, autoplay: Bool) {
        playingAlbum = album
        originalQueueIDs = Set(tracks.map(\.id))
        playingArtworkKey = nil
        playingArtwork = nil
        player.loadRemoteTracks(tracks, collection: album.title, artist: album.artist, startTrack: index, autoplay: autoplay,
                                maximumTracks: album.kind == .playlists ? PlexParser.musicPlaylistLimit : 250)
    }

    private func refreshPlayingArtwork(at index: Int) {
        guard let album = playingAlbum, playingTracks.indices.contains(index) else { return }
        let track = playingTracks[index]
        let loadingOriginalArtwork = album.kind != .playlists && originalQueueIDs.contains(track.id)
        let path = loadingOriginalArtwork ? album.artworkPath ?? track.artworkPath : track.artworkPath
        let key = path.map { ArtworkKey(collection: artworkCollection, path: $0) }
        guard key != playingArtworkKey else { return }
        playingArtworkKey = key
        if let key, let cached = artwork.object(forKey: key.path as NSString) {
            playingArtwork = cached
            player.updateAlbumArtwork(cached)
        } else {
            playingArtwork = nil
            player.updateAlbumArtwork(nil)
            if let key {
                fetchImage(for: key) { [weak self] image in
                    guard let self, let image, self.playingArtworkKey == key else { return }
                    self.playingArtwork = image
                    self.player.updateAlbumArtwork(image)
                }
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
        let cache = launchSnapshot?.listings.values.contains { entries in entries.contains { $0.artworkPath == key.path } } == true
        request.cancel = service.musicArtwork(path: key.path, server: serverID, library: libraryID, cache: cache) { [weak self] data in
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
        guard !serverID.isEmpty, !cachingCovers else { return }
        let generation = UUID()
        cacheGeneration = generation
        cachingCovers = true
        coverCacheStatus = "Checking selected libraries…"
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
        coverCacheStatus = "Canceled. Downloaded artwork was kept."
    }

    private static func cacheSummary(saved: Int, skipped: Int) -> String {
        let text = "\(saved) \(saved == 1 ? "image" : "images") cached"
        return skipped == 0 ? text : text + " · \(skipped) unavailable"
    }

    private func loadEntries(append: Bool) async throws {
        let setting = UserDefaults.standard.string(forKey: LibraryPageSize.preferenceKey)
            .flatMap(LibraryPageSize.init(rawValue:)) ?? .standard
        var start = append ? offset : 0
        if !append {
            more = false
            listingQuery = query
            entries = selectedGroup == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                launchSnapshot?.server == serverID && launchSnapshot?.library == libraryID
                ? launchSnapshot?.listings[kind] ?? [] : []
        }
        let group = selectedGroup
        let requestedKind: MusicKind = group == nil ? kind : .albums
        let requestedQuery = group == nil ? listingQuery.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var accumulated = append ? entries : []
        var seen = Set(accumulated.map(\.id))
        var hasMore: Bool
        repeat {
            let result = try await request {
                service.musicEntries(kind: requestedKind, query: requestedQuery, offset: start,
                                     limit: setting.batch, group: group, completion: $0)
            }
            try Task.checkCancellation()
            let unique = result.items.filter { seen.insert($0.id).inserted }
            start += result.rawCount
            hasMore = !unique.isEmpty && result.hasMore
            accumulated.append(contentsOf: unique)
        } while setting == .all && hasMore
        if group == nil, requestedQuery.isEmpty, !append {
            var snapshot = launchSnapshot.flatMap { $0.server == serverID && $0.library == libraryID ? $0 : nil }
                ?? LibrarySnapshot(server: serverID, library: libraryID, servers: servers, libraries: libraries)
            snapshot.servers = servers
            snapshot.libraries = libraries
            snapshot.listings[requestedKind] = Array(accumulated.prefix(120))
            launchSnapshot = snapshot
            if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.snapshotKey) }
        }
        if kind != requestedKind && group == nil && reconnecting {
            try await loadEntries(append: false)
            return
        }
        entries = accumulated
        offset = start
        more = hasMore
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
