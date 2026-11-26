import AVKit
import SwiftUI

enum PlexVideoKind: String, CaseIterable, Identifiable {
    case movies = "movie"
    case television = "show"

    var id: String { rawValue }
    var title: String { self == .movies ? "Movies" : "TV" }
    var icon: String { self == .movies ? "film" : "tv" }
    var plexType: String { self == .movies ? "1" : "2" }
}

struct PlexVideoItem: Identifiable, Equatable {
    let id: String
    let type: String
    let title: String
    let subtitle: String
    let summary: String
    let thumb: String?
}

struct PlexVideoPage {
    let items: [PlexVideoItem]
    let next: Int?
}

struct PlexVideoSource {
    let direct: [URL]
    let fallback: URL
}

struct PlexVideoBrowser: View {
    let kind: PlexVideoKind
    let server: String
    let service: PlexService
    let pauseMusic: () -> Void

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

    private var preference: String { "PlexVideoLibrary.\(kind.rawValue).\(server)" }
    private var parent: PlexVideoItem? { trail.last }
    private var episodes: Bool { parent?.type == "season" }
    private var requestKey: [String] { [server, kind.rawValue, selection, parent?.id ?? "", query, String(retry)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if parent != nil {
                    Button("Back", systemImage: "chevron.left") { trail.removeLast() }
                        .labelStyle(.iconOnly)
                }
                Text(parent?.title ?? kind.title).font(.largeTitle.bold()).lineLimit(1)
                Spacer()
                if !libraries.isEmpty {
                    Picker("Video Library", selection: $selection) {
                        ForEach(libraries, id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden().accessibilityLabel("Switch \(kind.title) Library")
                }
            }
            if parent == nil && !selection.isEmpty {
                TextField("Search \(kind.title)", text: $query)
                #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                #endif
            }
            if let summary = parent?.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            ScrollView {
                if episodes {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            Button { presentation = item } label: {
                                HStack(spacing: 15) {
                                    poster(item).frame(width: 100, height: 62)
                                    labels(item)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 18)], spacing: 22) {
                        ForEach(items) { item in
                            Button {
                                if item.type == "movie" { presentation = item }
                                else { trail.append(item) }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    poster(item).aspectRatio(2 / 3, contentMode: .fit)
                                    labels(item)
                                }
                            }
                        }
                    }
                }
                if let message {
                    VStack(spacing: 8) {
                        Text(message).foregroundStyle(.secondary)
                        Button("Retry") {
                            if libraries.isEmpty { discoveryRetry += 1 }
                            else { retry += 1 }
                        }
                    }.padding(16)
                } else if busy {
                    ProgressView().padding(16)
                } else if items.isEmpty {
                    Text(libraries.isEmpty ? "No \(kind.title) libraries on this Plex server." : "No matches.")
                        .foregroundStyle(.secondary).padding(16)
                }
                if let next, message == nil {
                    Button("Load more") { Task { await load(offset: next, generation: generation) } }
                        .disabled(busy)
                }
            }
        }
        .padding(20)
        .task(id: discoveryRetry) { await discover() }
        .task(id: requestKey) {
            let current = UUID()
            generation = current
            items = []
            next = nil
            if !selection.isEmpty {
                await load(offset: 0, generation: current)
            }
        }
        .onChange(of: selection) { _, value in
            if !value.isEmpty { UserDefaults.standard.set(value, forKey: preference) }
            trail = []
        }
        .sheet(item: $presentation) { item in
            PlexVideoPlayback(title: item.title, server: server, section: selection, item: item,
                             service: service, pauseMusic: pauseMusic)
        }
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        180
        #else
        130
        #endif
    }

    private func poster(_ item: PlexVideoItem) -> some View {
        PlexVideoPoster(path: item.thumb, server: server, service: service, icon: kind.icon)
    }

    private func labels(_ item: PlexVideoItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(2)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            let preferred = UserDefaults.standard.string(forKey: preference)
            selection = found.first(where: { $0.id == preferred })?.id ?? found.first?.id ?? ""
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
            let page = try await service.videoPage(server: server, kind: kind, section: selection,
                                                   parent: parent, query: query, offset: offset)
            try Task.checkCancellation()
            guard generation == current else { return }
            let previous = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !previous.contains($0.id) })
            next = page.next
        } catch {
            if !Task.isCancelled && generation == current { message = error.localizedDescription }
        }
    }
}

private struct PlexVideoPoster: View {
    let path: String?
    let server: String
    let service: PlexService
    let icon: String
    @State private var image: Image?

    var body: some View {
        Color.primary.opacity(0.07)
            .overlay {
                if let image { image.resizable().scaledToFill() }
                else { Image(systemName: icon).font(.title).foregroundStyle(.secondary) }
            }
            .clipShape(.rect(cornerRadius: 12))
            .task(id: path) {
                image = nil
                guard let path, let data = try? await service.videoPoster(server: server, path: path),
                      !Task.isCancelled else { return }
                #if os(macOS)
                if let artwork = NSImage(data: data) { image = Image(nsImage: artwork) }
                #else
                if let artwork = UIImage(data: data) { image = Image(uiImage: artwork) }
                #endif
            }
            .accessibilityHidden(true)
    }
}

private struct PlexVideoPlayback: View {
    let title: String
    let server: String
    let section: String
    let item: PlexVideoItem
    let service: PlexService
    let pauseMusic: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var relay: PlexVideoManifest?
    @State private var failure: String?
    @State private var mode = ""
    @State private var forceTranscode = false
    @State private var source: PlexVideoSource?
    @State private var pending = true
    @State private var resumeAt = CMTime.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if !mode.isEmpty { Text(mode).font(.caption).foregroundStyle(.secondary) }
                if mode == "Direct Play" { Button("Use Compatibility Mode", action: switchToCompatibility) }
                Button("Done") { dismiss() }
            }.padding(12)
            if let failure {
                Text(failure).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pending {
                ProgressView("Preparing video…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 450)
        #endif
        .background(.black)
        .environment(\.colorScheme, .dark)
        .task(id: forceTranscode) { await prepare() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { event in
            guard let failed = event.object as? AVPlayerItem, failed === player.currentItem else { return }
            playbackFailed()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
            relay = nil
            if mode == "Plex Transcode", let source { service.stopVideo(source.fallback) }
        }
    }

    private func switchToCompatibility() {
        resumeAt = player.currentTime()
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
        pending = true
        failure = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        do {
            let resolved: PlexVideoSource
            if let source { resolved = source }
            else {
                resolved = try await service.videoSource(server: server, section: section, item: item)
                try Task.checkCancellation()
                source = resolved
            }
            var direct: AVURLAsset?
            if !forceTranscode {
                for url in resolved.direct {
                    let asset = AVURLAsset(url: url)
                    if (try? await canDirectPlay(asset)) == true { direct = asset; break }
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            let playback: AVPlayerItem
            if let direct {
                playback = AVPlayerItem(asset: direct)
                mode = "Direct Play"
            } else {
                let loader = PlexVideoManifest()
                playback = AVPlayerItem(asset: loader.asset(resolved.fallback))
                relay = loader
                mode = "Plex Transcode"
            }
            pauseMusic()
            player.replaceCurrentItem(with: playback)
            pending = false
            player.play()
            let statuses = playback.publisher(for: \.status).values
            for await status in statuses {
                guard !Task.isCancelled, playback === player.currentItem else { return }
                if status == .failed { playbackFailed(); return }
                if status == .readyToPlay, forceTranscode, resumeAt.isNumeric, resumeAt.seconds > 0 {
                    let position = resumeAt
                    resumeAt = .zero
                    await player.seek(to: position)
                }
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription; pending = false }
        }
    }
}
