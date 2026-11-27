import AVKit
import SwiftUI

enum PlexVideoKind: String, CaseIterable, Identifiable {
    case movies = "movie"
    case television = "show"

    var id: String { rawValue }
    var title: String { self == .movies ? "Movies" : "TV Shows" }
    var icon: String { self == .movies ? "film" : "tv" }
    var plexType: String { self == .movies ? "1" : "2" }

    func libraryPreference(server: String) -> String { "PlexVideoLibrary.\(rawValue).\(server)" }

    func selectedLibrary(from libraries: [PlexLibrary], server: String) -> PlexLibrary? {
        let preferred = UserDefaults.standard.string(forKey: libraryPreference(server: server))
        return libraries.first(where: { $0.id == preferred }) ?? libraries.first
    }
}

struct PlexVideoItem: Identifiable, Equatable, Codable {
    let id: String
    let type: String
    let title: String
    let subtitle: String
    let summary: String
    let thumb: String?
}

struct PlexVideoSnapshot: Codable {
    let server: String
    let library: PlexLibrary
    let items: [PlexVideoItem]

    private static func key(_ kind: PlexVideoKind) -> String { "PlexVideoSnapshot." + kind.rawValue }

    static func restore(kind: PlexVideoKind, server: String) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: key(kind)),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.server == server else { return nil }
        return snapshot
    }

    static func clear() {
        for kind in PlexVideoKind.allCases { UserDefaults.standard.removeObject(forKey: key(kind)) }
    }

    func save(kind: PlexVideoKind) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(kind)) }
    }
}

struct PlexVideoPage {
    let items: [PlexVideoItem]
    let next: Int?
}

struct PlexVideoFile {
    let url: URL
    let container: String

    var isMatroska: Bool {
        ["mkv", "matroska", "webm"].contains(container.lowercased()) ||
        ["mkv", "webm"].contains(url.pathExtension.lowercased())
    }
}

struct PlexVideoVersion: Identifiable {
    let id: Int
    let label: String
    let file: PlexVideoFile?
}

struct PlexVideoSource {
    let versions: [PlexVideoVersion]
    let showID: String?
    let transcodeEndpoint: URL

    func fallback(version: Int) -> URL? {
        guard var parts = URLComponents(url: transcodeEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [
            .init(name: "mediaIndex", value: String(version)),
            .init(name: "session", value: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        ]
        return parts.url
    }
}

struct PlexOrderedEpisode {
    let item: PlexVideoItem
    let season: Int?
    let number: Int?
    let watched: Bool
}

struct PlexEpisodePage {
    let episodes: [PlexOrderedEpisode]
    let count: Int
    let total: Int?
}

struct VideoPosterGridLayout {
    let columns: [GridItem]
    let cardInset: CGFloat
    let posterWidth: CGFloat
    var posterHeight: CGFloat { posterWidth * 1.5 }

    init(availableWidth: CGFloat, size: LibraryArtworkSize) {
        #if os(tvOS)
        let baseWidth: CGFloat = 180
        #else
        let baseWidth: CGFloat = 130
        #endif
        let spacing: CGFloat = 18
        let preferredWidth = (baseWidth * size.scale).rounded()
        let width = max(1, availableWidth)
        let count = max(1, Int((width + spacing) / (preferredWidth + spacing)))
        let fittedWidth = floor((width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let cardWidth = min(fittedWidth, floor(preferredWidth * 1.3))
        cardInset = min(8, (cardWidth - 1) / 2)
        posterWidth = cardWidth - cardInset * 2
        columns = Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .top), count: count)
    }
}

struct PlexVideoBrowser: View {
    let kind: PlexVideoKind
    let server: String
    let service: PlexService
    let serverReady: Bool
    let connectionError: String?
    let retryConnection: () -> Void
    let pauseMusic: () -> Void

    @State private var snapshot: PlexVideoSnapshot?
    @State private var discovered = false
    @State private var libraries = [PlexLibrary]()
    @State private var selection = ""
    @State private var trail = [PlexVideoItem]()
    @State private var items = [PlexVideoItem]()
    @State private var query = ""
    @State private var next: Int?
    @State private var message: String?
    @State private var busy = true
    @State private var retry = 0
    @State private var discoveryRetry = 0
    @State private var generation = UUID()
    @State private var presentation: PlexVideoItem?
    @State private var matching: PlexVideoItem?
    @AppStorage(LibraryPageSize.preferenceKey) private var pageSize = LibraryPageSize.standard
    @AppStorage(LibraryArtworkSize.videoPosterPreferenceKey) private var posterSize = LibraryArtworkSize.medium
    @State private var recent = [VideoWatchRecord]()
    @State private var watchedItems = Set<String>()

    init(kind: PlexVideoKind, server: String, service: PlexService, serverReady: Bool,
         connectionError: String?, retryConnection: @escaping () -> Void, pauseMusic: @escaping () -> Void) {
        self.kind = kind
        self.server = server
        self.service = service
        self.serverReady = serverReady
        self.connectionError = connectionError
        self.retryConnection = retryConnection
        self.pauseMusic = pauseMusic
        let saved = PlexVideoSnapshot.restore(kind: kind, server: server)
        _snapshot = State(initialValue: saved)
        _libraries = State(initialValue: saved.map { [$0.library] } ?? [])
        _selection = State(initialValue: saved?.library.id ?? "")
        _items = State(initialValue: saved?.items ?? [])
    }

    private var ready: Bool { serverReady && discovered && !selection.isEmpty }
    private var showingRoot: Bool { parent == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var preference: String { kind.libraryPreference(server: server) }
    private var parent: PlexVideoItem? { trail.last }
    private var episodes: Bool { parent?.type == "season" }
    private var requestKey: [String] { [String(ready), selection, parent?.id ?? "", query, pageSize.rawValue, String(retry)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            LibraryBrowseHeader {
                browseTitle
                    .frame(maxWidth: .infinity, alignment: .leading)
            } controls: {
                browseControls
            }
            #else
            VStack(alignment: .leading, spacing: 14) {
                browseTitle
                browseControls
            }
            #endif
            VStack(alignment: .leading, spacing: 14) {
                if let summary = parent?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                GeometryReader { viewport in
                    videoScroll(availableWidth: viewport.size.width)
                }
            }
            .pageTransition(on: [selection, parent?.id ?? ""])
            .clipped()
            #if os(macOS)
            .padding(.horizontal, 28)
            #endif
        }
        #if !os(macOS)
        .padding(14)
        #endif
        .task(id: [String(serverReady), String(discoveryRetry)]) {
            if serverReady { await discover() }
            else { discovered = false }
        }
        .task(id: requestKey) {
            let current = UUID()
            generation = current
            items = showingRoot && snapshot?.library.id == selection ? snapshot?.items ?? [] : []
            next = nil
            refreshWatchState()
            if ready { await load(offset: 0, generation: current) }
        }
        .onChange(of: selection) { _, value in
            if !value.isEmpty { UserDefaults.standard.set(value, forKey: preference) }
            trail = []
            items = showingRoot && snapshot?.library.id == value ? snapshot?.items ?? [] : []
            refreshWatchState()
        }
        .sheet(item: $matching) { item in
            PlexVideoMatchEditor(item: item, server: server, section: selection, service: service) {
                retry += 1
            }
        }
        #if os(macOS)
        .sheet(item: $presentation, onDismiss: refreshWatchState, content: videoSession)
        #else
        .fullScreenCover(item: $presentation, onDismiss: refreshWatchState, content: videoSession)
        #endif
    }

    private func videoScroll(availableWidth: CGFloat) -> some View {
        ScrollView {
            if parent == nil, query.isEmpty, !recent.isEmpty { continueWatching }
            if episodes {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        Button { presentation = item } label: {
                            HStack(spacing: 15) {
                                poster(item).frame(width: 100, height: 62)
                                labels(item)
                                Spacer()
                                Image(systemName: watchedItems.contains(item.id) ? "checkmark.circle.fill" : "play.circle")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                            .glassHover(lift: true)
                            .contextMenu { watchActions(item) }
                    }
                }
            } else {
                posterGrid(VideoPosterGridLayout(availableWidth: availableWidth, size: posterSize))
            }
            if !serverReady {
                if let connectionError {
                    VStack(spacing: 8) {
                        Text(connectionError).foregroundStyle(.secondary)
                        Button("Retry", action: retryConnection)
                    }.padding(16)
                } else {
                    ProgressView("Reconnecting to Plex…").padding(16)
                }
            } else if let message {
                VStack(spacing: 8) {
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry") {
                        if !discovered { discoveryRetry += 1 }
                        else { retry += 1 }
                    }
                }.padding(16)
            } else if busy {
                ProgressView().padding(16)
            } else if items.isEmpty {
                Text(libraries.isEmpty ? "No \(kind.title) libraries on this Plex server." : "No matches.")
                    .foregroundStyle(.secondary).padding(16)
            }
            if let next, message == nil, pageSize != .all {
                Button("Load more") { Task { await load(offset: next, generation: generation) } }
                    .disabled(busy)
            }
        }
        .libraryScrollTopInset()
    }

    private func posterGrid(_ layout: VideoPosterGridLayout) -> some View {
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                Button {
                    if item.type == "movie" { presentation = item }
                    else { trail.append(item) }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        poster(item).frame(width: layout.posterWidth, height: layout.posterHeight)
                        HStack(alignment: .top) {
                            labels(item, reservesSpace: true)
                            if watchedItems.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill").accessibilityLabel("Watched")
                            }
                        }
                        .frame(width: layout.posterWidth, alignment: .leading)
                    }
                    .padding(layout.cardInset)
                    .background(Color.primary.opacity(0.10), in: .rect(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(.card)
                #else
                .buttonStyle(.plain)
                #endif
                .glassHover(lift: true)
                .disabled(!ready)
                .contextMenu {
                    if ready && item.type == "movie" { watchActions(item) }
                    if ready && item.type == kind.rawValue {
                        Button("Fix Match", systemImage: "magnifyingglass") { matching = item }
                    }
                }
            }
        }
    }

    private var browseTitle: some View {
        HStack {
            if parent != nil {
                Button("Back", systemImage: "chevron.left") { trail.removeLast() }
                    .labelStyle(.iconOnly)
            }
            Text(parent?.title ?? kind.title)
                #if os(macOS)
                .font(.system(size: 31, weight: .bold))
                #else
                .font(.largeTitle.bold())
                #endif
                .lineLimit(1)
        }
    }

    private var browseControls: some View {
        LibraryBrowseControls(placeholder: "Search " + kind.title.lowercased(),
                              query: parent == nil && !selection.isEmpty ? $query : nil,
                              searchDisabled: !ready) {
            if !libraries.isEmpty {
                Picker("Video Library", selection: $selection) {
                    ForEach(libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .accessibilityLabel("Switch " + kind.title + " Library")
                .disabled(!ready)
            }
        }
    }

    private func videoSession(_ item: PlexVideoItem) -> some View {
        PlexVideoSession(item: item, server: server, section: selection, service: service, pauseMusic: pauseMusic)
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching").font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(recent, id: \.item.id) { record in
                        Button { presentation = record.item } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                poster(record.item).frame(width: 150, height: 86)
                                labels(record.item)
                                Text("Resume at " + videoTime(record.seconds))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(width: 150, alignment: .leading)
                        }.glassHover(lift: true)
                        .disabled(!ready).contextMenu { if ready { watchActions(record.item) } }
                    }
                }
            }
        }.padding(.bottom, 18)
    }

    @ViewBuilder
    private func watchActions(_ item: PlexVideoItem) -> some View {
        if watchedItems.contains(item.id) {
            Button("Mark Unwatched") {
                VideoWatchStore.shared.clear(server: server, library: selection, id: item.id)
                refreshWatchState()
            }
        } else {
            Button("Mark Watched") {
                VideoWatchStore.shared.update(server: server, library: selection, item: item, seconds: 0, watched: true)
                refreshWatchState()
            }
            if recent.contains(where: { $0.item.id == item.id }) {
                Button("Remove from Continue Watching") {
                    VideoWatchStore.shared.clear(server: server, library: selection, id: item.id)
                    refreshWatchState()
                }
            }
        }
    }

    private func refreshWatchState() {
        recent = VideoWatchStore.shared.recent(server: server, library: selection)
        watchedItems = VideoWatchStore.shared.watchedIDs(server: server, library: selection)
    }

    private func poster(_ item: PlexVideoItem) -> some View {
        PlexVideoPoster(path: item.thumb, server: server, section: selection, service: service, icon: kind.icon,
                        cachedOnly: !ready, cache: showingRoot && snapshot?.library.id == selection &&
                            snapshot?.items.contains { $0.id == item.id && $0.thumb == item.thumb } == true)
    }

    private func labels(_ item: PlexVideoItem, reservesSpace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline)
                .lineLimit(2, reservesSpace: reservesSpace)
                .multilineTextAlignment(.leading)
            if reservesSpace || !item.subtitle.isEmpty {
                Text(item.subtitle.isEmpty ? " " : item.subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: reservesSpace)
                    .accessibilityHidden(item.subtitle.isEmpty)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func discover() async {
        busy = true
        message = nil
        defer { if !Task.isCancelled { busy = false } }
        do {
            let found = try await service.videoLibraries(server: server, kind: kind)
            try Task.checkCancellation()
            libraries = found
            selection = kind.selectedLibrary(from: found, server: server)?.id ?? ""
            discovered = true
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func load(offset: Int, generation current: UUID) async {
        guard !selection.isEmpty, offset == 0 || !busy else { return }
        busy = true
        message = nil
        defer { if generation == current && !Task.isCancelled { busy = false } }
        do {
            if parent == nil && !query.isEmpty { try await Task.sleep(for: .milliseconds(280)) }
            let size = pageSize
            var cursor: Int? = offset
            var seen = Set(offset == 0 ? [] : items.map(\.id))
            while let currentOffset = cursor {
                let page = try await service.videoPage(server: server, kind: kind, section: selection,
                                                       parent: parent, query: query, offset: currentOffset, size: size.batch)
                try Task.checkCancellation()
                guard generation == current else { return }
                let fresh = page.items.filter { seen.insert($0.id).inserted }
                if currentOffset == 0 {
                    items = fresh
                    if showingRoot, let library = libraries.first(where: { $0.id == selection }) {
                        let previews = items.prefix(60).map {
                            PlexVideoItem(id: $0.id, type: $0.type, title: $0.title, subtitle: $0.subtitle,
                                          summary: String($0.summary.prefix(400)), thumb: $0.thumb)
                        }
                        let saved = PlexVideoSnapshot(server: server, library: library, items: previews)
                        saved.save(kind: kind)
                        snapshot = saved
                    }
                } else {
                    items.append(contentsOf: fresh)
                }
                next = fresh.isEmpty ? nil : page.next
                cursor = size == .all ? next : nil
            }
            refreshWatchState()
        } catch {
            if !Task.isCancelled && generation == current { message = error.localizedDescription }
        }
    }
}

struct PlexVideoMatch: Identifiable {
    let id: String
    let title: String
    let year: Int?
}

private struct PlexVideoMatchEditor: View {
    let item: PlexVideoItem
    let server: String
    let section: String
    let service: PlexService
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var year = ""
    @State private var results = [PlexVideoMatch]()
    @State private var choice: PlexVideoMatch?
    @State private var message: String?
    @State private var busy = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Fix Match").font(.title2.bold())
            Text(item.title).foregroundStyle(.secondary)
            HStack {
                TextField("Title", text: $title)
                TextField("Year (optional)", text: $year).frame(maxWidth: 190)
                Button("Search") { Task { await search() } }
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .disabled(saving)
            if busy { ProgressView(saving ? "Saving match…" : "Searching Plex…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(results) { result in
                        Button {
                            choice = result
                        } label: {
                            HStack {
                                Text(result.title)
                                if let year = result.year { Text(String(year)).foregroundStyle(.secondary) }
                                Spacer()
                                if choice?.id == result.id { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                }
            }.frame(maxHeight: 320).disabled(busy)
            HStack {
                Button("Cancel") { dismiss() }.disabled(saving)
                Spacer()
                Button("Apply Match") { if let choice { Task { await apply(choice) } } }
                    .buttonStyle(.borderedProminent).disabled(choice == nil || busy)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 520, height: 465)
        #endif
        .interactiveDismissDisabled(saving)
        .task {
            title = item.title
            year = item.subtitle
            await search()
        }
    }

    private func search() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        choice = nil
        results = []
        message = nil
        do {
            results = try await service.videoMatches(server: server, section: section, item: item, title: title, year: year)
            if results.isEmpty { message = "No matches found. Try another title or clear the year." }
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

    private func apply(_ match: PlexVideoMatch) async {
        guard !busy else { return }
        busy = true
        saving = true
        defer { busy = false; saving = false }
        do {
            try await service.applyVideoMatch(server: server, section: section, item: item, match: match)
            didSave()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

private struct PlexVideoPoster: View {
    let path: String?
    let server: String
    let section: String
    let service: PlexService
    let icon: String
    var cachedOnly = false
    var cache = false
    @State private var image: Image?
    @State private var loadedKey: [String]?

    private var artworkKey: [String] { [server, section, path ?? ""] }

    var body: some View {
        Color.primary.opacity(0.07)
            .overlay {
                if loadedKey == artworkKey, let image { image.resizable().scaledToFill() }
                else { Image(systemName: icon).font(.title).foregroundStyle(.secondary) }
            }
            .clipShape(.rect(cornerRadius: 12))
            .task(id: artworkKey + [String(cachedOnly), String(cache)]) {
                guard let path else { image = nil; return }
                guard let data = try? await service.videoPoster(server: server, section: section, path: path,
                                                                cachedOnly: cachedOnly, cache: cache),
                      !Task.isCancelled else { return }
                loadedKey = artworkKey
                #if os(macOS)
                if let artwork = NSImage(data: data) { image = Image(nsImage: artwork) }
                #else
                if let artwork = UIImage(data: data) { image = Image(uiImage: artwork) }
                #endif
            }
            .accessibilityHidden(true)
    }
}

private struct PlexVideoSession: View {
    @State var item: PlexVideoItem
    let server: String
    let section: String
    let service: PlexService
    let pauseMusic: () -> Void

    var body: some View {
        PlexVideoPlayback(title: item.title, server: server, section: section, item: item,
                          service: service, pauseMusic: pauseMusic) { next in
            item = next
        }.id(item.id)
    }
}

private struct PlexVideoPlayback: View {
    let title: String
    let server: String
    let section: String
    let item: PlexVideoItem
    let service: PlexService
    let pauseMusic: () -> Void
    let advance: (PlexVideoItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @MusicAppearance private var appearance
    @State private var player = AVPlayer()
    @AppStorage(VideoSubtitleMode.preferenceKey) private var subtitleMode = VideoSubtitleMode.off
    @State private var relay: PlexVideoManifest?
    @State private var failure: String?
    @State private var mode = ""
    @State private var forceTranscode = false
    @State private var source: PlexVideoSource?
    @State private var native: URL?
    @State private var pending = true
    @State private var resumeAt = CMTime.zero
    @State private var lastSaved = 0.0
    @State private var watched = false
    @State private var hasPrepared = false
    @State private var avReady = false
    @State private var selectedVersion = -1
    @State private var activeVersion: Int?
    @State private var activeFallback: URL?
    @State private var nextEpisode: PlexVideoItem?
    @State private var autoAdvance = true
    @State private var countdown = 5
    @State private var nextStatus: String?
    #if os(macOS)
    @State private var presentation = MacVideoPresentation()
    #else
    @State private var fullscreen = false
    #endif

    private var playbackKey: [Int] { [selectedVersion, forceTranscode ? 1 : 0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer()
                    if !mode.isEmpty { Text(mode).font(.caption).foregroundStyle(.secondary) }
                    #if os(macOS)
                    if !pending && failure == nil {
                        Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") {
                            presentation.show(.fullscreen, title: title)
                        }
                        Button("Picture in Picture", systemImage: "pip.enter") {
                            presentation.show(.floating, title: title)
                        }
                    }
                    #else
                    if !pending && failure == nil {
                        Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { fullscreen.toggle() }
                            .labelStyle(.iconOnly)
                    }
                    #endif
                    Button("Done") { dismiss() }
                }
                if (source?.versions.count ?? 0) > 1 || mode == "Direct Play" {
                    ViewThatFits(in: .horizontal) {
                        HStack { versionControls }
                        VStack(alignment: .leading) { versionControls }
                    }
                }
            }
            .padding(12)
            .musicGlass(appearance, radius: 16)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            #if !os(macOS)
            .frame(height: fullscreen ? 0 : nil)
            .clipped()
            .opacity(fullscreen ? 0 : 1)
            .accessibilityHidden(fullscreen)
            .allowsHitTesting(!fullscreen)
            #endif
            if let nextEpisode {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(autoAdvance ? "Up Next in \(countdown)s" : "Up Next").font(.headline)
                        Text(nextEpisode.title).lineLimit(1)
                        if !nextEpisode.subtitle.isEmpty {
                            Text(nextEpisode.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if autoAdvance { Button("Cancel") { autoAdvance = false } }
                    Button("Play Next") { advance(nextEpisode) }.buttonStyle(.borderedProminent)
                }.padding(12)
            } else if let nextStatus {
                Text(nextStatus).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            if let failure {
                Text(failure).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pending {
                ProgressView("Preparing video…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let native {
                NativeVideoPlayer(url: native, startAt: resumeAt.seconds, subtitleMode: subtitleMode, progress: saveProgress) { seconds in
                    resumeAt = CMTime(seconds: seconds >= 5 ? seconds : lastSaved, preferredTimescale: 1_000)
                    forceTranscode = true
                }
                #if os(macOS)
                .environment(\.macVideoPresentation, presentation)
                #endif
                .id(native)
            } else {
                #if os(macOS)
                MacVideoSurface<AVPlayerView>(presentation: presentation, make: {
                    let view = AVPlayerView()
                    view.controlsStyle = .inline
                    view.showsFullScreenToggleButton = false
                    view.player = player
                    return view
                }, release: { $0.player = nil }, togglePlayback: {
                    if player.rate == 0 { player.play() } else { player.pause() }
                }).frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                SystemVideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 450)
        #endif
        #if !os(macOS)
        .overlay(alignment: .topTrailing) {
            if fullscreen {
                Button("Exit Fullscreen", systemImage: "arrow.down.right.and.arrow.up.left") { fullscreen = false }
                    .buttonStyle(.bordered).padding()
            }
        }
        #endif
        #if os(tvOS)
        .onExitCommand {
            if fullscreen { fullscreen = false } else { dismiss() }
        }
        #endif
        .background(.black)
        .foregroundStyle(appearance.text)
        .tint(appearance.accent)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .onChange(of: failure) { _, message in
            if message != nil { presentation.end() }
        }
        #endif
        .task(id: playbackKey) { await prepare() }
        .task(id: watched) { if watched { await queueNext() } }
        .task(id: nextEpisode?.id) { await runCountdown() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { event in
            guard let failed = event.object as? AVPlayerItem, failed === player.currentItem else { return }
            playbackFailed()
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if avReady { saveProgress(player.currentTime().seconds, false) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in
            guard let ended = event.object as? AVPlayerItem, ended === player.currentItem else { return }
            saveProgress(0, true)
        }
        .onDisappear {
            #if os(macOS)
            presentation.end()
            #endif
            if avReady { saveProgress(player.currentTime().seconds, false) }
            player.pause()
            player.replaceCurrentItem(with: nil)
            stopFallback()
        }
    }

    @ViewBuilder
    private var versionControls: some View {
        if let versions = source?.versions, versions.count > 1 {
            Picker("Version", selection: Binding(get: { selectedVersion }, set: selectVersion)) {
                Text("Automatic").tag(-1)
                ForEach(versions) { Text($0.label).tag($0.id) }
            }
            .accessibilityLabel("Video version")
        }
        if mode == "Direct Play" { Button("Use Compatibility Mode", action: switchToCompatibility) }
    }

    private func selectVersion(_ index: Int) {
        guard index != selectedVersion else { return }
        let position = watched ? 0 : avReady ? player.currentTime().seconds : lastSaved
        if position.isFinite && position >= 0 {
            resumeAt = CMTime(seconds: position, preferredTimescale: 1_000)
        }
        watched = false
        autoAdvance = true
        nextEpisode = nil
        nextStatus = nil
        selectedVersion = index
        activeVersion = nil
        forceTranscode = false
    }

    private func stopFallback() {
        relay = nil
        if let activeFallback {
            service.stopVideo(activeFallback)
            self.activeFallback = nil
        }
    }

    private func queueNext() async {
        guard item.type == "episode" else { return }
        guard let showID = source?.showID else {
            nextStatus = "Couldn’t identify this show for Up Next."
            return
        }
        nextStatus = "Finding the next unwatched episode…"
        let played = VideoWatchStore.shared.watchedIDs(server: server, library: section)
        do {
            let next = try await service.nextVideoEpisode(server: server, section: section,
                                                         showID: showID, after: item.id, excluding: played)
            try Task.checkCancellation()
            nextStatus = next == nil ? "You’re caught up with this show." : nil
            countdown = 5
            nextEpisode = next
        } catch {
            if !Task.isCancelled { nextStatus = "Couldn’t look up the next episode." }
        }
    }

    private func runCountdown() async {
        guard let nextEpisode else { return }
        for seconds in (1...5).reversed() {
            guard autoAdvance, !Task.isCancelled else { return }
            countdown = seconds
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        if autoAdvance && !Task.isCancelled { advance(nextEpisode) }
    }

    private func saveProgress(_ seconds: Double, _ ended: Bool) {
        guard !watched, ended || (seconds.isFinite && seconds >= 5) else { return }
        lastSaved = seconds
        watched = ended
        VideoWatchStore.shared.update(server: server, library: section, item: item, seconds: seconds, watched: ended)
    }

    private func switchToCompatibility() {
        let seconds = player.currentTime().seconds
        resumeAt = CMTime(seconds: seconds >= 5 ? seconds : lastSaved, preferredTimescale: 1_000)
        forceTranscode = true
    }

    private func playbackFailed() {
        if mode == "Direct Play" && !forceTranscode { switchToCompatibility() }
        else { failure = "Plex couldn’t play this video. Check that video transcoding is enabled and available on your server." }
    }

    private func canDirectPlay(_ asset: AVURLAsset) async throws -> Bool {
        guard try await asset.load(.isPlayable) else { return false }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let video = videoTracks.first, try await video.load(.isDecodable) {
            if audioTracks.isEmpty { return true }
            for audio in audioTracks where (try? await audio.load(.isDecodable)) == true { return true }
        }
        return false
    }

    private func prepare() async {
        #if !os(macOS)
        fullscreen = false
        #endif
        pending = true
        failure = nil
        avReady = false
        if !hasPrepared {
            hasPrepared = true
            let record = VideoWatchStore.shared.record(server: server, library: section, id: item.id)
            lastSaved = record?.canResume == true ? record?.seconds ?? 0 : 0
            resumeAt = CMTime(seconds: lastSaved, preferredTimescale: 1_000)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        native = nil
        stopFallback()
        do {
            let resolved: PlexVideoSource
            if let source { resolved = source }
            else {
                resolved = try await service.videoSource(server: server, section: section, item: item,
                                                         subtitleMode: subtitleMode)
                try Task.checkCancellation()
                source = resolved
            }
            let versions = selectedVersion < 0 ? resolved.versions : resolved.versions.filter { $0.id == selectedVersion }
            var direct: AVURLAsset?
            var directVersion: Int?
            if !forceTranscode {
                for version in versions {
                    guard let file = version.file, !file.isMatroska else { continue }
                    let asset = AVURLAsset(url: file.url)
                    if (try? await canDirectPlay(asset)) == true {
                        direct = asset
                        directVersion = version.id
                        break
                    }
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            if !forceTranscode, direct == nil {
                let nativeVersion = versions.first { $0.file?.isMatroska == true } ?? versions.first { $0.file != nil }
                if let nativeVersion, let file = nativeVersion.file {
                    pauseMusic()
                    native = file.url
                    activeVersion = nativeVersion.id
                    mode = "Direct Play · VLC"
                    pending = false
                    return
                }
            }
            let playback: AVPlayerItem
            if let direct {
                playback = AVPlayerItem(asset: direct)
                activeVersion = directVersion
                mode = "Direct Play"
            } else {
                let version = activeVersion ?? versions.first?.id ?? 0
                guard let fallback = resolved.fallback(version: version) else {
                    throw PlexServiceError("Couldn’t prepare Plex video playback.")
                }
                let loader = PlexVideoManifest()
                playback = AVPlayerItem(asset: loader.asset(fallback))
                relay = loader
                activeFallback = fallback
                activeVersion = version
                mode = "Plex Transcode"
            }
            pauseMusic()
            #if !os(macOS)
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playback, mode: .moviePlayback)
            try? audioSession.setActive(true)
            #endif
            player.replaceCurrentItem(with: playback)
            pending = false
            let statuses = playback.publisher(for: \.status).values
            for await status in statuses {
                guard !Task.isCancelled, playback === player.currentItem else { return }
                if status == .failed { playbackFailed(); return }
                if status == .readyToPlay {
                    if subtitleMode == .off, !forceTranscode, mode == "Direct Play",
                       let group = try? await playback.asset.loadMediaSelectionGroup(for: .legible) {
                        guard !Task.isCancelled, playback === player.currentItem else { return }
                        playback.select(nil, in: group)
                    }
                    if resumeAt.isNumeric, resumeAt.seconds > 0 {
                        let position = resumeAt
                        resumeAt = .zero
                        if !playback.duration.isNumeric || position < playback.duration { await player.seek(to: position) }
                    }
                    guard !Task.isCancelled, playback === player.currentItem else { return }
                    avReady = true
                    player.play()
                }
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription; pending = false }
        }
    }
}

#if !os(macOS)
private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        func playerViewController(_ controller: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
            completion(controller.viewIfLoaded?.window != nil)
        }
    }
}
#endif

private func videoTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}
