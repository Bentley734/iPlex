import SwiftUI
#if os(macOS)
import ToolDriveMac
#else
import ToolDriveMobile
#endif

struct GlobalLibrarySearch: View {
    @ObservedObject var library: LibraryModel
    let archive: ToolDriveTransport
    var credit: PlexVideoCredit?
    let select: (@escaping () -> Void) -> Void
    let openVideo: (PlexVideoKind, PlexVideoItem) -> Void

    @ObservedObject private var downloads = MediaDownloads.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var results = [Group]()
    @State private var searching = false
    @State private var unavailable = false

    private struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let open: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(credit?.name ?? "Search iPlex").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            if credit == nil {
                TextField("Search your libraries", text: $query)
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .focused($searchFocused)
            }
            if searching { ProgressView("Searching…") }
            if unavailable { Text("Some Plex results could not be loaded.").font(.callout).foregroundStyle(.secondary) }
            List {
                ForEach(results) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            Button {
                                select(row.open)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title).font(.headline)
                                    if !row.subtitle.isEmpty { Text(row.subtitle).font(.callout).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
                if results.isEmpty && !searching {
                    Text(query.isEmpty && credit == nil ? "Enter a title, artist, venue, or date." : "No matching titles.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 460)
        #endif
        .onAppear {
            #if !os(tvOS)
            searchFocused = credit == nil
            #endif
        }
        .task(id: [query, library.serverID, library.libraryID]) { await search() }
    }

    @MainActor
    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        unavailable = false
        searching = credit != nil || !term.isEmpty
        guard searching else { return }
        if credit == nil {
            try? await Task.sleep(for: .milliseconds(275))
            guard !Task.isCancelled else { return }
            results = localResults(term)
        }
        async let movies = videoResults(.movies, query: term)
        async let television = videoResults(.television, query: term)
        async let music = musicResults(term)
        let groups = await (movies, television, music)
        guard !Task.isCancelled else { return }
        results = (groups.0 + groups.1 + groups.2).filter { !$0.rows.isEmpty } + results
        searching = false
    }

    @MainActor
    private func localResults(_ term: String) -> [Group] {
        let offline = downloads.items.filter { "\($0.title) \($0.detail)".localizedCaseInsensitiveContains(term) }
            .prefix(12).map { item in
                Row(id: item.id.uuidString, title: item.title, subtitle: item.detail) {
                    library.selectedDownload = item
                    library.selectDownloads()
                }
            }
        let recordings = archive.searchRecordings(term).map { recording in
            Row(id: String(recording.id), title: recording.venue, subtitle: recording.date) {
                archive.openRecording(recording.id)
                library.selectToolDrive()
            }
        }
        return [Group(id: "toolDrive", title: library.sectionName(.toolDrive), rows: recordings),
                Group(id: "downloads", title: library.sectionName(.downloads), rows: Array(offline))].filter { !$0.rows.isEmpty }
    }

    @MainActor
    private func videoResults(_ kind: PlexVideoKind, query: String) async -> [Group] {
        let server = library.serverID
        guard library.videoServerReady else { return [] }
        do {
            let libraries = try await library.service.videoLibraries(server: server, kind: kind)
            guard let section = kind.selectedLibrary(from: libraries, server: server)?.id, !Task.isCancelled else { return [] }
            let page = try await library.service.videoPage(server: server, kind: kind, section: section, parent: nil,
                                                           query: query, offset: 0, size: 15, credit: credit)
            let title = library.sectionName(HeaderBrandSection(video: kind))
            var groups = [Group(id: kind.rawValue, title: title, rows: videoRows(page.items, kind: kind))]
            if kind == .television, credit == nil, !Task.isCancelled {
                let episodes = try await library.service.videoPage(server: server, kind: kind, section: section, parent: nil,
                                                                   query: query, offset: 0, size: 15, searchEpisodes: true)
                groups.append(Group(id: "episode", title: "Episodes", rows: videoRows(episodes.items, kind: kind)))
            }
            return groups
        } catch {
            if !Task.isCancelled { unavailable = true }
            return []
        }
    }

    private func videoRows(_ items: [PlexVideoItem], kind: PlexVideoKind) -> [Row] {
        items.map { item in
            let subtitle = [item.seriesTitle, item.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return Row(id: item.id, title: item.title, subtitle: subtitle) { openVideo(kind, item) }
        }
    }

    @MainActor
    private func musicResults(_ query: String) async -> [Group] {
        guard credit == nil, library.videoServerReady, !library.libraryID.isEmpty else { return [] }
        var groups = [Group]()
        for kind in [MusicKind.albums, .tracks] {
            guard !Task.isCancelled else { break }
            do {
                let items = try await library.searchMusic(kind, query: query)
                let rows = items.map { item in
                    Row(id: item.id, title: item.title, subtitle: item.artist) {
                        library.selectVideoSection(nil)
                        library.selectKind(kind)
                        if kind == .tracks { library.playLibraryTrack(item) }
                        else { library.open(item) }
                    }
                }
                groups.append(Group(id: kind.rawValue, title: kind == .albums ? "Albums" : "Tracks", rows: rows))
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
        return groups
    }
}
