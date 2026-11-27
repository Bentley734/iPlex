import Foundation
#if !os(tvOS)
import SQLite3
#endif

struct VideoWatchRecord: Codable {
    let server: String
    let library: String
    let item: PlexVideoItem
    let seconds: Double
    let watched: Bool
    let updatedAt: Double
    var explicitlyUnwatched: Bool? = nil

    var canResume: Bool { seconds >= 5 && !watched }
}

@MainActor
final class VideoWatchStore {
    static let shared = VideoWatchStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    #if os(tvOS)
    private let defaultsKey = "VideoWatchState.v1"
    #else
    private var database: OpaquePointer?
    #endif

    private init() {
        #if !os(tvOS)
        let folder = URL.applicationSupportDirectory.appending(path: "iPlex", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        let path = folder.appending(path: "VideoLibrary.sqlite").path
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK { sqlite3_close(handle); return }
        sqlite3_busy_timeout(handle, 1_000)
        let schema = """
            CREATE TABLE IF NOT EXISTS watch_state (
                server_id TEXT NOT NULL, library_id TEXT NOT NULL, item_id TEXT NOT NULL,
                updated_at REAL NOT NULL, watched INTEGER NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(server_id, library_id, item_id)
            );
            CREATE INDEX IF NOT EXISTS watch_recent
                ON watch_state(server_id, library_id, watched, updated_at DESC);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(handle); return }
        database = handle
        #endif
    }

    func recent(server: String, library: String) -> [VideoWatchRecord] {
        #if os(tvOS)
        records().filter { $0.server == server && $0.library == library && $0.canResume }.prefix(24).map { $0 }
        #else
        query("""
            SELECT payload FROM watch_state WHERE server_id = ? AND library_id = ? AND watched = 0
            ORDER BY updated_at DESC LIMIT 24
            """, [server, library]).filter(\.canResume)
        #endif
    }

    func watchedIDs(server: String, library: String) -> Set<String> {
        #if os(tvOS)
        Set(records().filter { $0.server == server && $0.library == library && $0.watched }.map { $0.item.id })
        #else
        var result = Set<String>()
        withStatement("SELECT item_id FROM watch_state WHERE server_id = ? AND library_id = ? AND watched = 1",
                      [server, library]) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 0) { result.insert(String(cString: value)) }
            }
        }
        return result
        #endif
    }

    func record(server: String, library: String, id: String) -> VideoWatchRecord? {
        #if os(tvOS)
        records().first { $0.server == server && $0.library == library && $0.item.id == id }
        #else
        query("SELECT payload FROM watch_state WHERE server_id = ? AND library_id = ? AND item_id = ?",
              [server, library, id]).first
        #endif
    }

    func update(server: String, library: String, item: PlexVideoItem, seconds: Double, watched: Bool,
                explicitlyUnwatched: Bool = false) {
        guard item.type == "movie" || item.type == "episode",
              seconds.isFinite, seconds <= 30 * 24 * 60 * 60, watched || explicitlyUnwatched || seconds >= 5 else { return }
        if !watched && !explicitlyUnwatched && record(server: server, library: library, id: item.id)?.watched == true { return }
        let snapshot = PlexVideoItem(id: item.id, type: item.type, title: String(item.title.prefix(200)),
                                     subtitle: String(item.subtitle.prefix(120)), summary: "", thumb: item.thumb)
        let value = VideoWatchRecord(server: server, library: library, item: snapshot,
                                     seconds: watched ? 0 : seconds, watched: watched,
                                     updatedAt: Date.now.timeIntervalSince1970, explicitlyUnwatched: explicitlyUnwatched ? true : nil)
        #if os(tvOS)
        let old = records().filter { $0.server != server || $0.library != library || $0.item.id != item.id }
        save([value] + old)
        #else
        guard let payload = try? encoder.encode(value) else { return }
        withStatement("INSERT OR REPLACE INTO watch_state VALUES (?, ?, ?, ?, ?, ?)", [server, library, item.id]) { statement in
            sqlite3_bind_double(statement, 4, value.updatedAt)
            sqlite3_bind_int(statement, 5, watched ? 1 : explicitlyUnwatched ? -1 : 0)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), Self.transient) }
            sqlite3_step(statement)
        }
        #endif
    }

    func clear(server: String, library: String, id: String) {
        #if os(tvOS)
        save(records().filter { $0.server != server || $0.library != library || $0.item.id != id })
        #else
        withStatement("DELETE FROM watch_state WHERE server_id = ? AND library_id = ? AND item_id = ?",
                      [server, library, id]) { sqlite3_step($0) }
        #endif
    }

    #if os(tvOS)
    private func records() -> [VideoWatchRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? decoder.decode([VideoWatchRecord].self, from: data)) ?? []
    }

    private func save(_ values: [VideoWatchRecord]) {
        var kept = Array(values.prefix(100))
        while let bytes = try? encoder.encode(kept) {
            if bytes.count <= 48_000 {
                UserDefaults.standard.set(bytes, forKey: defaultsKey)
                return
            }
            kept.removeLast()
        }
    }
    #else
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func withStatement(_ sql: String, _ parameters: [String], perform: (OpaquePointer) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), value, -1, Self.transient)
        }
        perform(statement)
    }

    private func query(_ sql: String, _ parameters: [String]) -> [VideoWatchRecord] {
        var result = [VideoWatchRecord]()
        withStatement(sql, parameters) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                if let decoded = try? decoder.decode(VideoWatchRecord.self, from: data) { result.append(decoded) }
            }
        }
        return result
    }
    #endif
}
