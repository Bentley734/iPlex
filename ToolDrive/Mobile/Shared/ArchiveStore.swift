import Foundation
import SwiftUI

struct SetlistEntry: Decodable, Hashable {
    let title: String
}

struct RecordingSource: Decodable, Identifiable, Hashable {
    let id: Int
    let rating: Double?
    let version, taper, gear, generation, length, status, lineage, recordingType, codec, lossless: String
    var searchText = ""
    enum CodingKeys: String, CodingKey {
        case id, rating, version, taper, gear, generation, length, status, lineage, recordingType, codec, lossless
    }
}

struct Concert: Decodable, Identifiable, Hashable {
    let id: Int
    let date, venue, city, state, country, status, festival, tour: String
    let setlist: [SetlistEntry]
    let songs: [String]
    let setlistOmitted: Int
    var sources: [RecordingSource]
    var dateLabel = ""
    var searchText = ""
    var year: Int { Int(date.prefix(4)) ?? 0 }
    var location: String { [city, state, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    enum CodingKeys: String, CodingKey {
        case id, date, venue, city, state, country, status, festival, tour, setlist, songs, setlistOmitted, sources
    }
}

struct ArchiveSnapshot: Decodable {
    let snapshotDate: String
    var songAlbums: [String: String]?
    var shows: [Concert]

    static func decode(_ data: Data) throws -> Self {
        var catalog = try JSONDecoder().decode(Self.self, from: data)
        guard !catalog.shows.isEmpty, catalog.shows.allSatisfy({ !$0.sources.isEmpty && $0.sources.allSatisfy { $0.status == "OTD" } }) else {
            throw UpdateError("Expected a catalog of shows with on-drive recordings.")
        }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(secondsFromGMT: 0)
        input.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.timeZone = input.timeZone
        display.dateStyle = .medium
        func index(_ values: [String]) -> String {
            values.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased().replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "œ", with: "oe")
        }
        for i in catalog.shows.indices {
            var show = catalog.shows[i]
            show.dateLabel = input.date(from: show.date).map(display.string(from:)) ?? show.date
            show.searchText = index([show.date, show.dateLabel, show.venue, show.location, show.status, show.festival, show.tour] + show.songs + show.setlist.map(\.title))
            for j in show.sources.indices {
                let s = show.sources[j]
                show.sources[j].searchText = index([String(s.id), s.version, s.taper, s.gear, s.generation, s.length, s.lineage, s.recordingType, s.codec, s.lossless, s.status])
            }
            catalog.shows[i] = show
        }
        return catalog
    }
}

@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var shows: [Concert] = []
    @Published private(set) var songAlbums: [String: String] = [:]

    func anniversaryShow(on date: Date = .now, in timeZone: TimeZone = .current) -> (show: Concert, yearsAgo: Int)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year, let month = today.month, let day = today.day else { return nil }
        let monthDay = String(format: "%02d-%02d", month, day)
        let match = shows.lazy.filter {
            $0.year > 0 && $0.year < year && $0.date.dropFirst(5) == monthDay
        }.max {
            $0.year == $1.year ? $0.id > $1.id : $0.year < $1.year
        }
        return match.map { ($0, year - $0.year) }
    }
    @Published private(set) var listenedIDs: [Int]
    @Published private(set) var savedIDs: Set<Int>
    @Published private(set) var onDriveCount = 0
    @Published private(set) var snapshotDate = ""
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = true
    @Published private(set) var updating = false
    @Published private(set) var updateMessage = ""
    @Published private(set) var wallpaperID: String
    @Published private(set) var wallpaperChoice: String
    @Published private(set) var customBackgroundRevision: UUID?
    @Published var home: HomeScreenPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(home) { defaults.set(data, forKey: "homeScreen") }
        }
    }
    @Published private(set) var theme: MobileTheme
    @Published private(set) var logo: MobileLogo
    @Published private(set) var topBarLogo: MobileLogo
    @Published var topBarLogoSize: HomeScreenPreferences.Logo {
        didSet { defaults.set(topBarLogoSize.rawValue, forKey: "catalogTopBarLogoSize") }
    }
    @Published private(set) var picture: FrontRowPicture
    @Published private(set) var glassEnabled: Bool
    @Published private(set) var glassAccent: GlassAccent
    @Published private(set) var glassOpacity: GlassOpacity
    var resolvedAccent: Color {
        guard theme.usesGlass, glassAccent != .original else { return theme.accent }
        return glassAccent.color
    }

    #if !os(tvOS)
    private var lastStandard: MobileTheme
    #endif

    nonisolated static var backgroundFile: URL {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Appearance/background.jpg")
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Appearance/background.jpg")
        #endif
    }
    private let appearance: GlassWallpaperPreferences
    private let defaults: UserDefaults
    private var loading = false
    private var activeUpdate: UpdateOperation?
    private var currentFile: URL?
    #if os(tvOS)
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Archive/catalog.json")
    #else
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Archive/catalog.json")
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var homePreferences = defaults.data(forKey: "homeScreen").flatMap {
            try? JSONDecoder().decode(HomeScreenPreferences.self, from: $0)
        } ?? HomeScreenPreferences()
        homePreferences.pins.removeAll { !HomeShortcut.configurable.contains($0) }
        home = homePreferences
        listenedIDs = defaults.array(forKey: "listenedConcertIDs") as? [Int] ?? []
        savedIDs = Set(defaults.array(forKey: "savedConcertIDs") as? [Int] ?? [])
        let storedTheme = defaults.string(forKey: "catalogTheme").flatMap(MobileTheme.init(rawValue:))
        let initialTheme = MobileTheme.selectableThemes.first { $0 == storedTheme } ?? .liquidGlass
        theme = initialTheme
        #if os(tvOS)
        if storedTheme != initialTheme {
            defaults.set(initialTheme.rawValue, forKey: "catalogTheme")
        }
        #else
        let remembered = defaults.string(forKey: "catalogLastStandardTheme").flatMap(MobileTheme.init(rawValue:))
        lastStandard = initialTheme == .liquidGlass ? (remembered == .liquidGlass ? .frontRow : remembered ?? .frontRow) : initialTheme
        #endif
        glassAccent = defaults.string(forKey: "catalogGlassAccent").flatMap(GlassAccent.init(rawValue:)) ?? .original
        glassOpacity = GlassOpacity((defaults.object(forKey: "catalogGlassOpacity") as? Int) ?? 50)
        let homeLogo = defaults.string(forKey: "catalogLogo").flatMap(MobileLogo.init(rawValue:)) ?? .classic
        logo = homeLogo
        topBarLogo = defaults.string(forKey: "catalogTopBarLogo").flatMap(MobileLogo.init(rawValue:)) ?? homeLogo
        topBarLogoSize = defaults.string(forKey: "catalogTopBarLogoSize").flatMap(HomeScreenPreferences.Logo.init(rawValue:)) ?? .medium
        picture = defaults.string(forKey: "catalogFrontRowPicture").flatMap(FrontRowPicture.init(rawValue:)) ?? .blueSilhouette
        glassEnabled = initialTheme.usesGlass || defaults.bool(forKey: "catalogLiquidGlass")
        let prefs = GlassWallpaperPreferences(defaults: defaults, wallpaperIDs: GlassWallpaper.choices.map(\.id))
        if initialTheme == .liquidGlass { prefs.enterTheme() }
        appearance = prefs
        wallpaperID = prefs.wallpaper
        wallpaperChoice = prefs.choice
        customBackgroundRevision = FileManager.default.fileExists(atPath: Self.backgroundFile.path) ? UUID() : nil
    }

    func selectTheme(_ selection: MobileTheme) {
        guard MobileTheme.selectableThemes.contains(selection) else { return }
        if selection == .liquidGlass {
            glassEnabled = true
            defaults.set(true, forKey: "catalogLiquidGlass")
            appearance.enterTheme()
            wallpaperID = appearance.wallpaper
        }
        #if !os(tvOS)
        if selection != .liquidGlass {
            lastStandard = selection
            defaults.set(selection.rawValue, forKey: "catalogLastStandardTheme")
        }
        #endif
        theme = selection
        defaults.set(selection.rawValue, forKey: "catalogTheme")
    }

    #if !os(tvOS)
    func setGlassEnabled(_ enabled: Bool) {
        if !enabled && theme == .liquidGlass { selectTheme(lastStandard) }
        glassEnabled = enabled
        defaults.set(enabled, forKey: "catalogLiquidGlass")
    }
    #endif

    func selectGlassAccent(_ accent: GlassAccent) {
        guard glassAccent != accent else { return }
        glassAccent = accent
        defaults.set(accent.rawValue, forKey: "catalogGlassAccent")
    }

    func setGlassOpacity(_ value: Int) {
        let updated = GlassOpacity(value)
        guard updated.percent != glassOpacity.percent else { return }
        glassOpacity = updated
        defaults.set(updated.percent, forKey: "catalogGlassOpacity")
    }

    func selectLogo(_ selection: MobileLogo) {
        if defaults.string(forKey: "catalogTopBarLogo") == nil {
            defaults.set(topBarLogo.rawValue, forKey: "catalogTopBarLogo")
        }
        logo = selection
        defaults.set(selection.rawValue, forKey: "catalogLogo")
    }

    func selectTopBarLogo(_ selection: MobileLogo) {
        topBarLogo = selection
        defaults.set(selection.rawValue, forKey: "catalogTopBarLogo")
    }

    func selectPicture(_ selection: FrontRowPicture) {
        picture = selection
        defaults.set(selection.rawValue, forKey: "catalogFrontRowPicture")
    }

    func selectWallpaper(_ id: String) {
        guard theme == .liquidGlass, appearance.select(id) else { return }
        wallpaperID = appearance.wallpaper
        wallpaperChoice = appearance.choice
    }

    func importBackground(_ input: @escaping @Sendable () async throws -> Data) async throws {
        let jpeg = try await Task.detached(priority: .userInitiated) {
            try await CustomBackground.jpeg(input())
        }.value
        try Task.checkCancellation()
        try CustomBackground.install(jpeg, at: Self.backgroundFile)
        customBackgroundRevision = UUID()
    }

    func removeCustomBackground() throws {
        do {
            try FileManager.default.removeItem(at: Self.backgroundFile)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {}
        customBackgroundRevision = nil
    }

    var recentlyListened: [Concert] {
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return listenedIDs.compactMap { byID[$0] }
    }

    func markListened(_ id: Int) {
        guard shows.contains(where: { $0.id == id }) else { return }
        listenedIDs.removeAll { $0 == id }
        listenedIDs.insert(id, at: 0)
        defaults.set(listenedIDs, forKey: "listenedConcertIDs")
    }

    func toggleListened(_ id: Int) {
        if listenedIDs.contains(id) {
            listenedIDs.removeAll { $0 == id }
            defaults.set(listenedIDs, forKey: "listenedConcertIDs")
        } else {
            markListened(id)
        }
    }

    func toggleSaved(_ id: Int) {
        if savedIDs.contains(id) { savedIDs.remove(id) } else { savedIDs.insert(id) }
        defaults.set(Array(savedIDs), forKey: "savedConcertIDs")
    }

    func load() async {
        guard shows.isEmpty, !loading else { return }
        guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "ToolDrive") else {
            isLoading = false
            loadError = "The bundled catalog is missing."
            return
        }
        loading = true
        isLoading = true
        loadError = nil
        defer { loading = false; isLoading = false }
        do {
            let cache = cacheURL
            let (snapshot, file) = try await Task.detached(priority: .userInitiated) {
                let bundledData = try Data(contentsOf: bundled)
                if FileManager.default.fileExists(atPath: cache.path),
                   let baseline = try JSONSerialization.jsonObject(with: bundledData) as? [String: Any],
                   let saved = try? CatalogUpdate.readCache(at: cache, relativeTo: baseline),
                   var snapshot = try? ArchiveSnapshot.decode(CatalogUpdate.serialize(saved.catalog)) {
                    if snapshot.songAlbums?.isEmpty != false { snapshot.songAlbums = baseline["songAlbums"] as? [String: String] }
                    return (snapshot, cache)
                }
                return (try ArchiveSnapshot.decode(bundledData), bundled)
            }.value
            apply(snapshot, file: file)
        } catch { loadError = error.localizedDescription }
    }

    private func apply(_ snapshot: ArchiveSnapshot, file: URL) {
        snapshotDate = snapshot.snapshotDate
        songAlbums = snapshot.songAlbums ?? [:]
        onDriveCount = snapshot.shows.reduce(0) { $0 + $1.sources.count }
        shows = snapshot.shows
        currentFile = file
    }

    func cancelUpdate() { activeUpdate?.cancel() }

    func refresh() async {
        guard let previousFile = currentFile, !updating else { return }
        updating = true
        updateMessage = "Checking the Tool Drive Project…"
        let operation = UpdateOperation()
        activeUpdate = operation
        defer { updating = false; activeUpdate = nil }
        do {
            let cache = cacheURL
            let (snapshot, summary) = try await Task.detached(priority: .utility) {
                let blobs = try CatalogUpdate.files.map { name in
                    try operation.fetch(LiveMediaParser.streamBaseURL.appendingPathComponent("data/" + name), limit: 16 * 1024 * 1024)
                }
                let today = ISO8601DateFormatter()
                today.formatOptions = [.withFullDate]
                let candidate = try CatalogUpdate.compile(blobs, date: today.string(from: Date()))
                let bytes = try Data(contentsOf: previousFile)
                guard let previous = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw UpdateError("The previous catalog could not be checked.")
                }
                let old = previous["catalog"] as? [String: Any] ?? previous
                try CatalogUpdate.validate(candidate)
                try CatalogUpdate.protect(old, candidate)
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try CatalogUpdate.serialize(candidate)
                let updated = try ArchiveSnapshot.decode(data)
                try operation.check()
                try data.write(to: cache, options: .atomic)
                return (updated, CatalogUpdate.summary(old, candidate))
            }.value
            apply(snapshot, file: cache)
            updateMessage = summary
        } catch { updateMessage = error.localizedDescription }
    }
}
