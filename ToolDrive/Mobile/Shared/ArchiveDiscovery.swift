import AVFoundation
import SwiftUI

private func songKey(_ title: String) -> String {
    title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "&", with: "and")
        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
}

struct CompareRecordings: View {
    let show: Concert
    let saveState: (RecordingSource) -> (label: String, enabled: Bool, message: String?)
    let save: (RecordingSource) -> Void
    @State private var expanded = false

    var body: some View {
        if show.sources.filter({ $0.streamVersion != nil }).count > 1 {
            VStack(alignment: .leading, spacing: 14) {
                Button { expanded.toggle() } label: {
                    Label("Compare Recordings", systemImage: "waveform")
                }
                .accessibilityIdentifier("recordings.compare")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded { RecordingComparison(show: show, saveState: saveState, save: save) }
            }
        }
    }
}

private struct RecordingComparison: View {
    struct Song: Identifiable {
        let id: String
        let title: String
        let matches: [Int: LiveTrack]
    }
    let show: Concert
    let saveState: (RecordingSource) -> (label: String, enabled: Bool, message: String?)
    let save: (RecordingSource) -> Void
    @EnvironmentObject private var player: AudioPlayer
    @State private var requests = RecordingTrackRequests()
    @State private var preview = RecordingPreview()
    @State private var songs: [Song] = []
    @State private var selection = ""
    @State private var previewSource: Int?
    @State private var message: String?
    @State private var loading = true
    @State private var missing = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading { ProgressView("Finding matching tracks…") }
            else if songs.isEmpty {
                Text(missing > 0 ? "Some tracklists couldn’t load. Try again to compare recordings." :
                     "No song could be matched across at least two recordings.").foregroundStyle(.secondary)
                if missing > 0 { Button("Retry", action: load) }
            } else {
                Picker("Song", selection: $selection) {
                    ForEach(songs) { Text($0.title).tag($0.id) }
                }
                .onChange(of: selection) { _, _ in stop() }
                if let song = songs.first(where: { $0.id == selection }) {
                    Text("Preview up to 30 seconds from each recording.").font(.caption).foregroundStyle(.secondary)
                    ForEach(show.sources) { source in
                        if let track = song.matches[source.id] {
                            VStack(alignment: .leading, spacing: 8) {
                                Text([source.version, source.taper, source.recordingType.capitalized]
                                    .filter { !$0.isEmpty && $0.lowercased() != "unknown" }.joined(separator: " · "))
                                    .font(.headline)
                                if let rating = source.rating {
                                    Text("Sound rating \(rating.formatted()) / 10").font(.caption).foregroundStyle(.secondary)
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack { actions(source, track: track) }.fixedSize()
                                    VStack(alignment: .leading) { actions(source, track: track) }
                                }
                                if let note = saveState(source).message {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).archivePanel()
                        }
                    }
                }
                if missing > 0 {
                    Text("\(missing) tracklists couldn’t load.").font(.caption).foregroundStyle(.secondary)
                    Button("Retry missing tracklists", action: load)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: load)
        .onDisappear { requests.cancel(); stop() }
        .onChange(of: player.isPlaying) { _, playing in if playing { stop() } }
    }

    @ViewBuilder private func actions(_ source: RecordingSource, track: LiveTrack) -> some View {
        Button {
            if previewSource == source.id { stop() }
            else {
                stop()
                player.pause()
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                    previewSource = source.id
                    preview.play(track.url) { error in previewSource = nil; message = error }
                } catch { message = "The audio output is unavailable." }
            }
        } label: {
            Label(previewSource == source.id ? "Stop" : "Preview",
                  systemImage: previewSource == source.id ? "stop.fill" : "play.fill")
        }
        Button("Stream") { stop(); player.stream(show: show, source: source, atTrack: track.number) }
        let state = saveState(source)
        Button(state.label) { stop(); save(source) }.disabled(!state.enabled)
    }

    private func stop() {
        preview.stop()
        previewSource = nil
        message = nil
    }

    private func load() {
        stop()
        loading = true
        let recordings = show.sources.compactMap { source in
            source.streamVersion.map { ArchiveRecording(sourceID: source.id, showID: show.id, date: show.date, version: $0) }
        }
        requests.load(recordings) { results in
            missing = recordings.count - results.count
            let known = Set((show.songs + show.setlist.map(\.title)).map(songKey))
            var titles = [String: String]()
            var matches = [String: [Int: LiveTrack]]()
            let tagsByTitle = Dictionary(grouping: results.values.flatMap { $0 }.filter { $0.songIDs.count == 1 },
                                         by: { songKey($0.title) }).mapValues { Set($0.flatMap(\.songIDs)) }
            for recording in recordings {
                var duplicate = Set<String>()
                var unique = [String: LiveTrack]()
                for track in results[recording] ?? [] where track.songIDs.count < 2 {
                    let title = songKey(track.title)
                    let inferred = tagsByTitle[title].flatMap { $0.count == 1 ? $0.first : nil }
                    guard !title.isEmpty, !track.songIDs.isEmpty || inferred != nil || known.contains(title) else { continue }
                    let key = (track.songIDs.first ?? inferred).map { "id:" + $0 } ?? "title:" + title
                    if unique.updateValue(track, forKey: key) != nil { duplicate.insert(key) }
                }
                for (key, track) in unique where !duplicate.contains(key) {
                    titles[key] = titles[key] ?? track.title
                    matches[key, default: [:]][recording.sourceID] = track
                }
            }
            songs = matches.compactMap { key, sources in
                guard sources.count >= 2, let title = titles[key] else { return nil }
                return Song(id: key, title: title, matches: sources)
            }.sorted { ($0.title.localizedStandardCompare($1.title) == .orderedSame)
                ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !songs.contains(where: { $0.id == selection }) { selection = songs.first?.id ?? "" }
            loading = false
        }
    }
}

private struct DiscoveryList<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var archive: ArchiveStore

    var body: some View {
        Group {
            #if os(tvOS)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    content()
                }
                .buttonStyle(.card)
                .padding(26)
                .frame(maxWidth: 1220)
                .frame(maxWidth: .infinity)
            }
            #else
            List { content() }.navigationTitle(title)
            #endif
        }
        .archivePage(wallpaperID: archive.wallpaperID)
    }
}

private struct DiscoveryRow: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 15)
            .archivePanel()
        #else
        content
        #endif
    }
}

struct LiveAlbumsView: View {
    var body: some View {
        DiscoveryList(title: "Albums") {
            ForEach(LiveAlbum.all) { album in
                NavigationLink {
                    LiveAlbumDetail(album: album)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(album.title).font(.headline)
                            if let year = album.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: { Image(systemName: "opticaldisc") }
                    .modifier(DiscoveryRow())
                }
                .accessibilityIdentifier("albums." + album.id)
            }
        }
    }
}

private struct LiveAlbumDetail: View {
    let album: LiveAlbum
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @State private var operation: UpdateOperation?
    @State private var requests = RecordingTrackRequests()
    @State private var tracklist: LiveAlbumTracklist?
    @State private var preparing = false
    @State private var message: String?

    var body: some View {
        DiscoveryList(title: album.title) {
            if let tracklist {
                Section("The TDP Live Album") {
                    if let day = tracklist.refreshedAt?.prefix(10) {
                        Text("Refreshed " + day).font(.caption).foregroundStyle(.secondary)
                    }
                    if tracklist.orderedTracks.contains(where: { $0.recordingId != nil }) {
                        Button { play(from: nil) } label: {
                            Label("Play Live Album", systemImage: "play.fill").modifier(DiscoveryRow())
                        }
                            .disabled(preparing)
                    }
                    ForEach(Array(tracklist.orderedTracks.enumerated()), id: \.offset) { _, row in
                        if row.recordingId != nil {
                            Button { play(from: row.trackOrder) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.title).font(.headline)
                                    Text([row.showDate, row.venue].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .modifier(DiscoveryRow())
                            }
                            .disabled(preparing)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title)
                                Text("No live pick yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if tracklist.orderedTracks.isEmpty { Text("No live tracklist is available yet.") }
                }
            }
            if operation != nil || preparing { ProgressView(preparing ? "Preparing album…" : "Loading live tracklist…") }
            if let message { Text(message).foregroundStyle(.secondary) }
            if operation == nil && tracklist == nil { Button("Retry", action: load) }
        }
        .onAppear { if tracklist == nil && operation == nil { load() } }
        .onDisappear {
            operation?.cancel()
            operation = nil
            requests.cancel()
            preparing = false
        }
    }

    private func load() {
        message = nil
        let request = UpdateOperation()
        operation = request
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try LiveAlbumTracklist.fetch(album, using: request) }
            DispatchQueue.main.async {
                guard operation === request else { return }
                operation = nil
                switch result {
                case .success(let value): tracklist = value
                case .failure: message = "Couldn’t load the live tracklist. Check your connection and try again."
                }
            }
        }
    }

    private func play(from start: Int?) {
        guard let tracklist else { return }
        message = nil
        preparing = true
        var bySource = [Int: ArchiveRecording]()
        for show in archive.shows {
            for source in show.sources {
                if let version = source.streamVersion {
                    bySource[source.id] = ArchiveRecording(sourceID: source.id, showID: show.id, date: show.date, version: version)
                }
            }
        }
        let rows = tracklist.orderedTracks.compactMap { row -> (LiveAlbumTrack, ArchiveRecording)? in
            guard let id = row.recordingId, let recording = bySource[id],
                  recording.date == row.showDate, recording.version == row.version else { return nil }
            return (row, recording)
        }
        requests.load(rows.map { $0.1 }) { manifests in
            preparing = false
            let tracks = LiveAlbumTracklist.playable(rows, in: manifests)
            let index = start == nil ? 0 : tracks.firstIndex { $0.row == start }
            guard !tracks.isEmpty, let index else {
                message = "This selection couldn’t be played. Check your connection and catalog updates."
                return
            }
            if tracks.count < tracklist.orderedTracks.filter({ $0.recordingId != nil }).count {
                message = "Some live picks couldn’t be loaded."
            }
            #if os(tvOS)
            let expand = true
            #else
            let expand = false
            #endif
            player.play(tracks: tracks.map(\.track), title: album.title, context: "The TDP Live Album",
                        startIndex: index, expandPlayer: expand)
        }
    }
}

private struct CatalogSong: Identifiable {
    let id: String
    let title: String
    let shows: [Concert]
}

struct ArchiveSongsView<Detail: View>: View {
    @EnvironmentObject private var archive: ArchiveStore
    @State private var query = ""
    @State private var album = ""
    @State private var songs: [CatalogSong] = []
    @ViewBuilder let detail: (Concert) -> Detail

    var body: some View {
        let albumsBySong = archive.songAlbums.reduce(into: [String: String]()) { result, row in
            result[songKey(row.key)] = row.value
        }
        let visible = songs.filter { song in
            (query.isEmpty || song.id.contains(songKey(query))) &&
            (album.isEmpty || (albumsBySong[song.id] ?? "other") == album)
        }
        DiscoveryList(title: "Songs") {
            TextField("Find a song", text: $query).autocorrectionDisabled()
            if !albumsBySong.isEmpty {
                Picker("Album", selection: $album) {
                    Text("All Albums").tag("")
                    ForEach(LiveAlbum.all) { Text($0.title).tag($0.id) }
                    Text("Other").tag("other")
                }
            }
            ForEach(visible) { song in
                NavigationLink {
                    SongPerformancesView(song: song, detail: detail)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.title).font(.headline)
                        let albumTitle = LiveAlbum.all.first { $0.id == albumsBySong[song.id] }?.title
                        Text([albumTitle, "\(song.shows.count) \(song.shows.count == 1 ? "show" : "shows")"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .modifier(DiscoveryRow())
                }
            }
            if visible.isEmpty { Text("No songs match your search.").foregroundStyle(.secondary) }
        }
        .task(id: archive.shows.count) {
            var titles = [String: String]()
            var shows = [String: [Concert]]()
            for show in archive.shows {
                var seen = Set<String>()
                for title in show.songs + show.setlist.map(\.title) {
                    let key = songKey(title)
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    titles[key] = titles[key] ?? title
                    shows[key, default: []].append(show)
                }
            }
            songs = shows.map { key, matches in
                CatalogSong(id: key, title: titles[key] ?? key, shows: matches)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

private struct SongPerformancesView<Detail: View>: View {
    let song: CatalogSong
    let detail: (Concert) -> Detail

    var body: some View {
        let matches = CatalogFilters().matches(song.shows, query: "", savedOnly: false, savedIDs: [], sort: .highest)
        DiscoveryList(title: song.title) {
            Section("Recorded performances") {
                ForEach(matches) { match in
                    NavigationLink { detail(match.show) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.show.venue.isEmpty ? match.show.date : match.show.venue).font(.headline)
                            Text([match.show.dateLabel, match.show.location,
                                  match.rating.map { $0.formatted() + " / 10" } ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .modifier(DiscoveryRow())
                    }
                }
            }
        }
    }
}
