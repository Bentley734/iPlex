import AVFoundation
import SwiftUI

struct LibraryTrack: Codable {
    let number: Int
    let title: String
    let duration: Double?
    let file: String
}

struct LibraryRecord: Identifiable, Codable {
    let id: UUID
    let key: String
    let title: String
    let context: String
    let date: Date
    let tracks: [LibraryTrack]

    var archiveShowID: Int? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "archive", Int(parts[2]) != nil else { return nil }
        return Int(parts[1])
    }
}

private enum LibraryDisk {
    private static func download(_ url: URL) async throws -> (URL, URLResponse) {
        if #available(iOS 15, tvOS 15, *) { return try await URLSession.shared.download(from: url) }
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.downloadTask(with: url) { file, response, error in
                guard let file, let response else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                    return
                }
                do {
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.moveItem(at: file, to: temporary)
                    continuation.resume(returning: (temporary, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }

    static func read(at root: URL) throws -> [LibraryRecord] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // The app may have closed before an earlier transfer finished.
        for folder in folders where folder.lastPathComponent.hasPrefix(".staging-") {
            if UUID(uuidString: String(folder.lastPathComponent.dropFirst(9))) != nil { try? fm.removeItem(at: folder) }
        }
        return folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let bytes = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                  let record = try? JSONDecoder().decode(LibraryRecord.self, from: bytes), record.id == id else { return nil }
            return record
        }.sorted { $0.date > $1.date }
    }

    static func save(_ tracks: [LiveTrack], to root: URL, title: String, context: String, key: String,
                     fromFiles: Bool, progress: @escaping @Sendable (Int) async -> Void) async throws -> LibraryRecord {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let staging = root.appendingPathComponent(".staging-" + id.uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var items = [LibraryTrack]()
        for (i, track) in tracks.enumerated() {
            try Task.checkCancellation()
            await progress(i)
            let ext = track.url.pathExtension.lowercased()
            let file = String(format: "%03d", i + 1) + (ext.isEmpty ? "" : "." + ext)
            let target = staging.appendingPathComponent(file)
            if fromFiles {
                let scoped = track.url.startAccessingSecurityScopedResource()
                defer { if scoped { track.url.stopAccessingSecurityScopedResource() } }
                if !scoped && fm.isReadableFile(atPath: track.url.path) {
                    try fm.copyItem(at: track.url, to: target)
                } else {
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: track.url, options: [], error: &coordinationError) { source in
                        do { try fm.copyItem(at: source, to: target) } catch { copyError = error }
                    }
                    if let error = copyError ?? coordinationError { throw error }
                }
            } else {
                guard track.url.scheme == "https", track.url.host == "tooldriveproject.net",
                      track.url.path.hasPrefix("/mp3_2.0/"), ext == "mp3" else {
                    throw UpdateError("This recording link is unavailable for offline saving.")
                }
                let (temporary, response) = try await download(track.url)
                defer { try? fm.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      http.url?.scheme == "https" else { throw UpdateError("The archive could not provide track \(i + 1).") }
                try fm.moveItem(at: temporary, to: target)
            }
            let asset = AVURLAsset(url: target)
            guard try await asset.archivePlayable(), !(try await asset.archiveAudioTracks()).isEmpty else {
                throw UpdateError("“\(track.title)” contains no playable audio.")
            }
            let measured = try? await asset.archiveDuration().seconds
            let duration = measured.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? track.duration
            items.append(LibraryTrack(number: track.number, title: track.title, duration: duration, file: file))
        }
        try Task.checkCancellation()
        let record = LibraryRecord(id: id, key: key, title: title, context: context, date: Date(), tracks: items)
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        // Keep the user's imports in iCloud Backup. Archive streams can be downloaded again.
        if !fromFiles {
            var folder = staging
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        }
        try fm.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString))
        return record
    }
}

@MainActor
final class MobileLibrary: ObservableObject {
    @Published private(set) var records: [LibraryRecord] = []
    @Published private(set) var activity: String?
    @Published private(set) var message = ""
    @Published private(set) var progress: Double = 0
    private var loading: Task<[LibraryRecord], Error>?
    private var work: Task<Void, Never>?

    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)) {
        self.directory = directory
        loading = Task.detached(priority: .utility) { try LibraryDisk.read(at: directory) }
        Task { await load() }
    }

    func load() async {
        guard let loading else { return }
        do {
            let saved = try await loading.value
            if self.loading != nil { records = saved }
        } catch { message = error.localizedDescription }
        self.loading = nil
    }

    func playable(_ record: LibraryRecord) -> [LiveTrack] {
        let folder = directory.appendingPathComponent(record.id.uuidString)
        return record.tracks.map { LiveTrack(number: $0.number, title: $0.title, duration: $0.duration, url: folder.appendingPathComponent($0.file)) }
    }

    func importFiles(_ files: [URL]) {
        let ordered = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = ordered.first else { return }
        let tracks = ordered.enumerated().map { i, url in
            LiveTrack(number: i + 1, title: url.deletingPathExtension().lastPathComponent, duration: nil, url: url)
        }
        let title = tracks.count == 1 ? tracks[0].title : first.deletingPathExtension().lastPathComponent + " + \(tracks.count - 1)"
        save(tracks, title: title, context: "Imported from Files", key: UUID().uuidString, fromFiles: true)
    }

    func download(tracks: [LiveTrack], title: String, context: String, key: String) {
        save(tracks, title: title, context: context, key: key, fromFiles: false)
    }

    private func save(_ tracks: [LiveTrack], title: String, context: String, key: String, fromFiles: Bool) {
        guard work == nil else { message = "Finish or cancel the current transfer in Library first."; return }
        guard !tracks.isEmpty else { message = "No tracks were found."; return }
        activity = title
        progress = 0
        message = ""
        work = Task {
            defer { activity = nil; work = nil }
            await load()
            guard !records.contains(where: { $0.key == key }) else { message = "This recording is already in your library."; return }
            do {
                let result = try await LibraryDisk.save(tracks, to: directory, title: title, context: context, key: key, fromFiles: fromFiles) { i in
                    await self.setProgress(i, count: tracks.count)
                }
                records.insert(result, at: 0)
                message = "Saved “\(title)” for offline playback."
            } catch {
                message = Task.isCancelled ? "Transfer canceled." : error.localizedDescription
            }
        }
    }

    private func setProgress(_ index: Int, count: Int) {
        progress = Double(index) / Double(count)
    }

    func cancel() { work?.cancel() }

    func delete(_ record: LibraryRecord) {
        let folder = directory.appendingPathComponent(record.id.uuidString)
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            // tvOS may reclaim a cached recording while its manifest is in memory.
            guard !FileManager.default.fileExists(atPath: folder.path) else {
                message = error.localizedDescription
                return
            }
        }
        records.removeAll { $0.id == record.id }
        message = ""
    }
}
