import Foundation
import SwiftUI

@MainActor
final class MobilePlex: ObservableObject {
    enum Activity { case idle, signingIn, servers, libraries, searching }
    #if os(iOS)
    struct SignInPage: Identifiable {
        let url: URL
        let id = UUID()
    }

    @Published var signInPage: SignInPage?
    #endif

    @Published private(set) var authorization: PlexAuthorizationSession?
    var pairingCode: String? { authorization?.code }

    @Published private(set) var connected: Bool
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var libraries: [PlexLibrary] = []
    @Published private(set) var serverID: String?
    @Published private(set) var libraryID: String?
    @Published private(set) var match: PlexSearchResult?
    @Published private(set) var message: String?

    private let service: PlexService
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var loadedServers = false

    init(defaults: UserDefaults = .standard, service: PlexService? = nil) {
        let actual = service ?? PlexService(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            defaults: defaults
        )
        self.service = actual
        connected = actual.status.connected
    }

    var hasPlexAccount: Bool { service.hasStoredAccount }
    var hasToolDriveLibrary: Bool { service.preferredLibraryID != nil }

    private var selectionChanged: Bool {
        serverID != service.preferredServerID || libraryID != service.preferredLibraryID
    }

    func open() {
        connected = hasPlexAccount
        if connected && (!loadedServers || selectionChanged) && activity == .idle { refresh() }
    }

    func signIn() {
        run(.signingIn) {
            #if os(tvOS)
            let method = PlexSignInMethod.linkCode
            #else
            let method = PlexSignInMethod.browser
            #endif
            let authorization = try await self.request { self.service.beginConnection(method: method, completion: $0) }
            self.authorization = authorization
            #if os(iOS)
            self.reopenSignIn()
            #endif
            let deadline = ProcessInfo.processInfo.systemUptime + Double(authorization.expiresIn)
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let state = try await self.request { self.service.pollConnection(pinID: authorization.pinID, completion: $0) }
                if state == .connected {
                    self.connected = true
                    self.clearAuthorization()
                    try await self.loadServers()
                    return
                }
            }
            throw PlexServiceError.expiredPIN
        }
    }

    #if os(iOS)
    func reopenSignIn() {
        if let authorization { signInPage = SignInPage(url: authorization.authorizationURL) }
    }
    #endif

    private func clearAuthorization() {
        authorization = nil
        #if os(iOS)
        signInPage = nil
        #endif
    }

    func refresh() {
        run(.servers) { try await self.loadServers() }
    }

    private func loadServers() async throws {
        activity = .servers
        loadedServers = false
        servers = []
        libraries = []
        serverID = nil
        libraryID = nil
        match = nil
        let found = try await request(service.refreshServers)
        connected = service.status.connected
        loadedServers = true
        servers = found
        guard !found.isEmpty else {
            message = "No Plex servers are available to this account."
            return
        }
        guard let selected = service.status.selectedServerID else {
            message = "Choose an available server in Plex settings, then try again."
            return
        }
        try await loadLibraries(on: selected)
    }

    func selectServer(_ id: String) {
        guard servers.contains(where: { $0.id == id }) else { return }
        run(.libraries) { try await self.loadLibraries(on: id) }
    }

    private func loadLibraries(on id: String) async throws {
        activity = .libraries
        libraryID = nil
        libraries = []
        match = nil
        if service.status.selectedServerID != id { try service.selectServer(id: id) }
        serverID = id
        libraries = try await request(service.refreshLibraries)
        libraryID = service.status.selectedLibraryID
        if libraries.isEmpty { message = "This server has no music libraries available to your account." }
    }

    func selectLibrary(_ id: String) {
        guard !id.isEmpty else { return }
        cancel()
        match = nil
        do {
            try service.selectLibrary(id: id)
            libraryID = service.status.selectedLibraryID
        } catch { message = error.localizedDescription }
    }

    func search(date: String) {
        guard connected, libraryID != nil else { return }
        match = nil
        run(.searching) {
            self.match = try await self.request { self.service.search(showDate: date, completion: $0) }
        }
    }

    func recording(show: Concert, source: RecordingSource, version: Int) async throws -> PlexSearchResult {
        try Task.checkCancellation()
        cancel()
        let id = operationID
        defer {
            if operationID == id {
                activity = .idle
                connected = service.status.connected
            }
        }
        return try await withTaskCancellationHandler {
            guard hasPlexAccount else {
                throw PlexServiceError("Link your account in iPlex Settings to stream this recording.")
            }
            let onDrive = show.sources.filter { $0.status == "OTD" }
            guard source.streamVersion == version, onDrive.contains(where: { $0.id == source.id && $0.streamVersion == version }) else {
                throw PlexServiceError("This recording is unavailable on the drive.")
            }
            guard onDrive.filter({ $0.streamVersion == version }).count == 1 else {
                throw PlexServiceError("Several archive recordings have this version. Plex cannot identify which one you selected.")
            }
            if !loadedServers || selectionChanged || serverID == nil || libraries.isEmpty { try await loadServers() }
            guard serverID != nil else {
                throw PlexServiceError("Choose an available server in Plex settings, then try again.")
            }
            guard libraryID != nil else {
                throw PlexServiceError("Choose a Tool Drive library in iPlex Settings, then try again.")
            }
            activity = .searching
            let soleOnDriveSource = onDrive.count == 1
            return try await request {
                service.search(showDate: show.date, preferredVersion: version, allowUnversionedAlbum: soleOnDriveSource, completion: $0)
            }
        } onCancel: {
            Task { @MainActor in
                if self.operationID == id { self.cancel() }
            }
        }
    }

    func play(_ result: PlexSearchResult, index: Int, with player: AudioPlayer) {
        do {
            let tracks = try result.validatedPlaybackTracks()
            guard tracks.indices.contains(index) else { return }
            player.play(tracks: tracks, title: result.collection, context: "Plex · \(result.showDate)",
                        startIndex: index, expandPlayer: false)
        } catch { message = error.localizedDescription }
    }

    func disconnect() {
        cancel()
        do {
            try service.disconnect()
        } catch { message = error.localizedDescription }
        connected = service.status.connected
        loadedServers = false
        match = nil
        servers = []
        libraries = []
        serverID = nil
        libraryID = nil
    }

    func cancel() {
        if activity == .servers || activity == .libraries { loadedServers = false }
        operationID = UUID()
        task?.cancel()
        task = nil
        _ = service.cancelSearch()
        activity = .idle
        connected = service.status.connected
        clearAuthorization()
        message = nil
    }

    private func run(_ activity: Activity, _ work: @escaping @MainActor () async throws -> Void) {
        cancel()
        self.activity = activity
        let id = operationID
        task = Task {
            do {
                try Task.checkCancellation()
                try await work()
            } catch {
                guard id == operationID, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            guard id == operationID else { return }
            connected = service.status.connected
            clearAuthorization()
            self.activity = .idle
            task = nil
        }
    }

    private func request<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        let id = operationID
        let value = try await withCheckedThrowingContinuation { continuation in
            start { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
        return value
    }
}

private struct IPlexPlexSettingsKey: EnvironmentKey {
    static let defaultValue: (() -> AnyView)? = nil
}

extension EnvironmentValues {
    var iplexPlexSettings: (() -> AnyView)? {
        get { self[IPlexPlexSettingsKey.self] }
        set { self[IPlexPlexSettingsKey.self] = newValue }
    }
}

#if !LEGACY_IOS
struct PlexStreamButton: View {
    let show: Concert
    let source: RecordingSource
    @EnvironmentObject private var plex: MobilePlex
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.iplexPlexSettings) private var plexSettings
    @State private var offerSetup = false
    @State private var showSettings = false

    var body: some View {
        Button {
            if plex.hasPlexAccount && (plexSettings == nil || plex.hasToolDriveLibrary) { player.stream(show: show, source: source, from: plex) }
            else { offerSetup = true }
        } label: {
            let active = player.isStreaming(source, fromPlex: true) && player.phase != .failed
            Label(active ? "Open Plex player" : "Stream from Plex", systemImage: active ? "waveform" : "play.fill")
        }
        .alert("Link Plex to stream this recording", isPresented: $offerSetup) {
            Button("Open Plex settings") { showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connect Plex and choose the Tool Drive library that contains your recordings.")
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showSettings, onDismiss: streamAfterSetup) { if let plexSettings { plexSettings() } else { TVPlexView() } }
        #else
        .sheet(isPresented: $showSettings, onDismiss: streamAfterSetup) { if let plexSettings { plexSettings() } else { PlexView() } }
        #endif
    }

    private func streamAfterSetup() {
        if plex.hasPlexAccount && (plexSettings == nil ? plex.libraryID != nil : plex.hasToolDriveLibrary) {
            player.stream(show: show, source: source, from: plex)
        }
    }
}
#endif
