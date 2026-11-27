import SwiftUI

struct OfflineMedia: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case music = "Music", movie = "Movies", episode = "TV Shows"
        var id: Self { self }
        var icon: String { self == .music ? "music.note" : self == .movie ? "film" : "tv" }
    }

    struct File: Codable, Identifiable {
        let name: String
        let title: String
        let duration: Double?
        var id: String { name }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let detail: String
    let files: [File]
    let added: Date
}

private final class MediaDownloadSession: NSObject, URLSessionDownloadDelegate {
    var progress: (@Sendable (Double) -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Plex playback URLs contain credentials. Never forward them to a redirect target.
        completionHandler(nil)
    }
}

@MainActor
final class MediaDownloads: ObservableObject {
    static let shared = MediaDownloads()
    @Published private(set) var items = [OfflineMedia]()
    @Published private(set) var status = ""
    struct Job: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let kind: OfflineMedia.Kind
        let resolve: @MainActor () async throws -> [Source]
        var error: String?
    }

    @Published private(set) var active: Job?
    @Published private(set) var pending: [Job] = []
    @Published private(set) var failed: [Job] = []
    @Published private(set) var progress: Double?
    private let directory: URL
    private var transfer: Task<Void, Never>?
    private let session: URLSession

    struct Source {
        let url: URL
        let title: String
        var duration: Double? = nil
        var format: String? = nil
    }

    init(directory: URL? = nil) {
        #if os(tvOS)
        let base = URL.cachesDirectory
        #else
        let base = URL.applicationSupportDirectory
        #endif
        self.directory = directory ?? base.appending(path: "iPlex/Offline Media", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: MediaDownloadSession(), delegateQueue: nil)
        reload()
    }

    deinit { session.invalidateAndCancel() }

    func url(_ file: OfflineMedia.File, in item: OfflineMedia) -> URL {
        folder(item.id).appending(path: file.name, directoryHint: .notDirectory)
    }

    func cancel() { transfer?.cancel() }

    func downloadVideo(service: PlexService, server: String, section: String, item: PlexVideoItem, version: Int? = nil) {
        start(title: item.title, detail: item.subtitle, kind: item.type == "episode" ? .episode : .movie) {
            let resolved = try await service.videoSource(server: server, section: section, item: item)
            let selected = version.flatMap { id in resolved.versions.first { $0.id == id } }
                ?? (version == nil ? resolved.versions.first(where: { $0.file != nil }) : nil)
            guard let file = selected?.file else { throw UpdateError("No original file is available to download.") }
            return [Source(url: file.url, title: item.title, format: file.container)]
        }
    }

    func start(title: String, detail: String, kind: OfflineMedia.Kind,
               resolve: @escaping @MainActor () async throws -> [Source]) {
        pending.append(Job(title: title, detail: detail, kind: kind, resolve: resolve))
        startNext()
    }

    func retry(_ job: Job) {
        failed.removeAll { $0.id == job.id }
        start(title: job.title, detail: job.detail, kind: job.kind, resolve: job.resolve)
    }

    func dismissJob(_ job: Job) {
        pending.removeAll { $0.id == job.id }
        failed.removeAll { $0.id == job.id }
    }

    private func startNext() {
        guard transfer == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let (id, title) = (job.id, job.title)
        active = job
        progress = nil
        status = "Preparing \(title)…"
        let staging = directory.appending(path: ".\(id.uuidString).partial", directoryHint: .isDirectory)
        transfer = Task {
            defer {
                try? FileManager.default.removeItem(at: staging)
                active = nil
                progress = nil
                transfer = nil
                startNext()
            }
            do {
                let sources = try await job.resolve()
                guard !sources.isEmpty else { throw UpdateError("No downloadable media was found.") }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var files = [OfflineMedia.File]()
                for (index, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    status = "Downloading \(title) · \(index + 1) of \(sources.count)"
                    let suffix = try Self.fileSuffix(source)
                    let name = "\(index + 1).\(suffix)"
                    let endpoint = try Self.downloadRequest(source.url)
                    let observer = MediaDownloadSession()
                    observer.progress = { [weak self] fraction in
                        let value = (Double(index) + fraction) / Double(sources.count)
                        Task { @MainActor [weak self] in
                            guard let self, self.active?.id == id else { return }
                            if self.progress == nil || value - (self.progress ?? 0) >= 0.01 || value == 1 {
                                self.progress = value
                            }
                        }
                    }
                    let (temporary, response) = try await session.download(for: endpoint, delegate: observer)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          !["text/html", "application/json", "application/xml", "text/xml"].contains(response.mimeType ?? ""),
                          (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                        throw UpdateError("Plex did not return a complete media file.")
                    }
                    try FileManager.default.moveItem(at: temporary, to: staging.appending(path: name))
                    files.append(.init(name: name, title: source.title, duration: source.duration))
                }
                let item = OfflineMedia(id: id, kind: job.kind, title: title, detail: job.detail, files: files, added: .now)
                try JSONEncoder().encode(item).write(to: staging.appending(path: "media.json"), options: .atomic)
                try FileManager.default.moveItem(at: staging, to: folder(id))
                items.insert(item, at: 0)
                status = "Saved \(title)."
            } catch {
                if Task.isCancelled {
                    status = "Download canceled."
                } else {
                    var entry = job
                    entry.error = (error as? UpdateError)?.localizedDescription
                        ?? "Check your Plex connection and available storage."
                    failed.append(entry)
                    status = "Could not download \(title)."
                }
            }
        }
    }

    func remove(_ item: OfflineMedia) {
        do {
            try FileManager.default.removeItem(at: folder(item.id))
            items.removeAll { $0.id == item.id }
            UserDefaults.standard.removeObject(forKey: Self.positionKey(item.id))
        } catch {
            status = "Could not remove \(item.title)."
        }
    }

    private static func positionKey(_ id: UUID) -> String { "OfflineVideoPosition." + id.uuidString }

    func position(for item: OfflineMedia) -> Double {
        UserDefaults.standard.double(forKey: Self.positionKey(item.id))
    }

    func rememberPosition(_ seconds: Double, finished: Bool, for item: OfflineMedia) {
        guard seconds.isFinite else { return }
        UserDefaults.standard.set(finished || seconds < 5 ? 0 : seconds, forKey: Self.positionKey(item.id))
    }

    private func folder(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }

    private func reload() {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        items = children.compactMap { child in
            if child.lastPathComponent.hasPrefix("."), child.pathExtension == "partial" {
                try? FileManager.default.removeItem(at: child)
                return nil
            }
            guard let id = UUID(uuidString: child.lastPathComponent),
                  let data = try? Data(contentsOf: child.appending(path: "media.json")),
                  let item = try? JSONDecoder().decode(OfflineMedia.self, from: data),
                  item.id == id, !item.files.isEmpty,
                  item.files.allSatisfy({ file in
                      file.name.range(of: #"^[0-9]+\.[a-z0-9]{2,10}$"#, options: .regularExpression) != nil &&
                      FileManager.default.fileExists(atPath: url(file, in: item).path)
                  }) else { return nil }
            return item
        }.sorted { $0.added > $1.added }
    }

    static func downloadRequest(_ source: URL) throws -> URLRequest {
        guard var parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.path.hasPrefix("/library/parts/"),
              let token = parts.queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value,
              !token.isEmpty else { throw UpdateError("This media file is not available on a secure Plex connection.") }
        parts.query = nil
        guard let url = parts.url else { throw UpdateError("The media file address is invalid.") }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    private static func fileSuffix(_ source: Source) throws -> String {
        let ext = source.url.pathExtension.lowercased()
        let suffix = ext.isEmpty ? source.format?.lowercased() ?? "" : ext
        guard suffix.range(of: #"^[a-z0-9]{2,10}$"#, options: .regularExpression) != nil else {
            throw UpdateError("The original file type is unknown.")
        }
        return suffix == "matroska" ? "mkv" : suffix
    }
}

struct DownloadsBrowser: View {
    @ObservedObject private var downloads = MediaDownloads.shared
    let library: LibraryModel
    @State private var video: OfflineMedia?
    @State private var removal: OfflineMedia?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 15) {
                    heading.fixedSize()
                    Spacer()
                    search.frame(width: 205)
                }
                VStack(spacing: 10) {
                    heading.frame(maxWidth: .infinity, alignment: .leading)
                    search.frame(maxWidth: 205)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.vertical, 20)
            if !downloads.status.isEmpty || !downloads.pending.isEmpty || !downloads.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !downloads.status.isEmpty { Text(downloads.status).foregroundStyle(.secondary) }
                        if downloads.active != nil {
                            HStack {
                                if let progress = downloads.progress { ProgressView(value: progress) }
                                else { ProgressView() }
                                Button("Cancel", action: downloads.cancel)
                            }
                        }
                        ForEach(downloads.pending) { job in
                            HStack {
                                Text(job.title)
                                Spacer()
                                Text("Queued").foregroundStyle(.secondary)
                                Button("Cancel") { downloads.dismissJob(job) }
                            }
                        }
                        ForEach(downloads.failed) { job in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.title)
                                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button("Retry") { downloads.retry(job) }
                                Button("Dismiss") { downloads.dismissJob(job) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                }
                .frame(maxHeight: min(180, CGFloat(54 + 42 * (downloads.pending.count + downloads.failed.count))))
            }
            if downloads.items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                    description: Text("Use Download in the Music, Movies, or TV Shows item menu. Tool Drive recordings are in its Library."))
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(OfflineMedia.Kind.allCases) { kind in
                            let rows = downloads.items.filter {
                                $0.kind == kind && (query.isEmpty || "\($0.title) \($0.detail)".localizedCaseInsensitiveContains(query))
                            }
                            if !rows.isEmpty { Text(kind.rawValue).font(.title2.bold()) }
                            ForEach(rows) { item in
                                Button {
                                    if kind == .music { library.playDownload(item) }
                                    else { library.player.pause(); video = item }
                                } label: {
                                    HStack {
                                        Image(systemName: kind.icon).frame(width: 26)
                                        VStack(alignment: .leading) {
                                            Text(item.title).font(.headline)
                                            if !item.detail.isEmpty { Text(item.detail).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if kind != .music, downloads.position(for: item) >= 5 {
                                            Label("Resume", systemImage: "play.circle")
                                        } else {
                                            Image(systemName: "play.circle")
                                        }
                                    }.padding(8).contentShape(Rectangle())
                                }
                                .contextMenu {
                                    Button("Remove Download", systemImage: "trash", role: .destructive) { removal = item }
                                }
                            }
                        }
                    }.padding(.horizontal, 28).padding(.top, 12)
                }
                .frame(maxWidth: 720)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: library.selectedDownload?.id, initial: true) { _, _ in
            guard let item = library.selectedDownload else { return }
            library.selectedDownload = nil
            if item.kind == .music { library.playDownload(item) }
            else { library.player.pause(); video = item }
        }
        .sheet(item: $video) { item in
            if let file = item.files.first {
                OfflineVideoSheet(title: item.title, url: downloads.url(file, in: item),
                                  startAt: downloads.position(for: item),
                                  progress: { downloads.rememberPosition($0, finished: $1, for: item) })
            }
        }
        .confirmationDialog("Remove Download?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { item in
            Button("Remove \(item.title)", role: .destructive) { downloads.remove(item); removal = nil }
        }
    }

    private var heading: some View {
        Text(library.sectionName(.downloads)).font(.largeTitle.bold())
    }

    private var search: some View {
        LibraryBrowseControls(placeholder: "Search downloads", query: $query, searchDisabled: false) { EmptyView() }
    }
}

private struct OfflineVideoSheet: View {
    let title: String
    let url: URL
    let startAt: Double
    let progress: (Double, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VideoSubtitleMode.preferenceKey) private var subtitles = VideoSubtitleMode.off
    @State private var failure = false
    #if os(macOS)
    @State private var presentation = MacVideoPresentation()
    #endif

    var body: some View {
        VStack {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                #if os(macOS)
                Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    presentation.show(.fullscreen, title: title)
                }
                #endif
                Button("Done") { dismiss() }
            }.padding()
            if failure { ContentUnavailableView("Unable to Play Download", systemImage: "exclamationmark.triangle") }
            else {
                NativeVideoPlayer(url: url, startAt: startAt, subtitleMode: subtitles, progress: progress,
                                  fallback: nil, onFailure: { failure = true })
                #if os(macOS)
                .environment(\.macVideoPresentation, presentation)
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 500)
        .onDisappear { presentation.end() }
        #endif
    }
}
