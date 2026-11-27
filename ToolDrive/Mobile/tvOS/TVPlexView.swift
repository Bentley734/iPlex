import SwiftUI

struct TVPlexView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var plex: MobilePlex
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.iplexPlexSettings) private var plexSettings
    @State private var showingPlexSettings = false
    @Environment(\.dismiss) private var dismiss
    @Namespace private var focusScope

    @State private var date = ""
    @State private var chooseServer = false
    @State private var chooseLibrary = false
    @State private var confirmDisconnect = false

    private var showDate: String { date.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSearch: Bool {
        plex.activity == .idle && plex.libraryID != nil &&
        (try? PlexParser.searchQueries(showDate: showDate, preferredVersion: nil)) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("Plex").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { dismiss() }.accessibilityIdentifier("tv.plex.done")
                }
                .focusSection()
                if let message = plex.message {
                    Text(message).font(.callout)
                        .accessibilityIdentifier("tv.plex.message")
                }
                if plexSettings != nil {
                    Button("Plex Settings") { showingPlexSettings = true }
                }
                if plex.connected {
                    HStack(alignment: .top, spacing: 36) {
                        if plexSettings == nil { connection }
                        if plex.libraryID != nil { search }
                    }
                    if let match = plex.match, match.showDate == showDate, plex.libraryID != nil {
                        recording(match)
                    }
                } else if plexSettings == nil {
                    linkAccount
                }
            }
            .padding(46)
            .frame(maxWidth: 1560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .focusScope(focusScope)
        .fullScreenCover(isPresented: $showingPlexSettings, onDismiss: plex.open) { plexSettings?() }
        .onAppear { plex.open() }
        .onDisappear { plex.cancel() }
        .onExitCommand { dismiss() }
        .confirmationDialog("Disconnect this Apple TV from Plex?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                if player.context.hasPrefix("Plex · ") { player.stop() }
                plex.disconnect()
            }
            .accessibilityIdentifier("tv.plex.confirmDisconnect")
            Button("Cancel", role: .cancel) {}
        }
        .tint(nil)
    }

    private var linkAccount: some View {
        VStack(alignment: .leading, spacing: 24) {
            if plex.activity == .signingIn {
                if let code = plex.pairingCode {
                    Text("Link this Apple TV").font(.title2.bold())
                    Text("On your phone or computer, open **plex.tv/link** and enter this code.")
                    Text(verbatim: code)
                        .font(.system(size: 88, weight: .bold, design: .monospaced))
                        .tracking(9)
                        .foregroundStyle(archive.resolvedAccent)
                        .accessibilityLabel("Link code " + code.map(String.init).joined(separator: " "))
                        .accessibilityIdentifier("tv.plex.code")
                } else {
                    ProgressView("Getting a Plex link code")
                }
                Button("Cancel linking") { plex.cancel() }
                    .accessibilityIdentifier("tv.plex.cancelSignIn")
            } else {
                Text("Stream recordings from a music library on your Plex server.").font(.title3)
                Button { plex.signIn() } label: { Label("Link Plex account", systemImage: "link") }
                    .prefersDefaultFocus(true, in: focusScope)
                    .accessibilityIdentifier("tv.plex.signIn")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(36).archivePanel()
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection").font(.title3.bold())
            if !plex.servers.isEmpty {
                Text("Server").font(.caption).foregroundStyle(archive.theme.muted)
                Button(plex.servers.first(where: { $0.id == plex.serverID })?.name ?? "Choose server") {
                    chooseServer = true
                }
                .accessibilityIdentifier("tv.plex.server")
                .disabled(plex.activity != .idle)
                .tint(archive.resolvedAccent)
                .confirmationDialog("Choose a Plex server", isPresented: $chooseServer) {
                    ForEach(plex.servers, id: \.id) { server in
                        Button(server.name) { if server.id != plex.serverID { plex.selectServer(server.id) } }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .tint(nil)
            }
            if !plex.libraries.isEmpty {
                Text("Music library").font(.caption).foregroundStyle(archive.theme.muted)
                Button(plex.libraries.first(where: { $0.id == plex.libraryID })?.name ?? "Choose library") {
                    chooseLibrary = true
                }
                .accessibilityIdentifier("tv.plex.library")
                .disabled(plex.activity != .idle)
                .tint(archive.resolvedAccent)
                .confirmationDialog("Choose a music library", isPresented: $chooseLibrary) {
                    ForEach(plex.libraries, id: \.id) { library in
                        Button(library.name) { plex.selectLibrary(library.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .tint(nil)
            }
            if plex.activity == .servers || plex.activity == .libraries {
                ProgressView(plex.activity == .servers ? "Finding servers" : "Finding music libraries")
            }
            Button("Refresh servers") { plex.refresh() }
                .disabled(plex.activity != .idle)
                .accessibilityIdentifier("tv.plex.refresh")
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                .accessibilityIdentifier("tv.plex.disconnect")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30).archivePanel().focusSection()
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Find a recording").font(.title3.bold())
            TextField("Show date (YYYY-MM-DD)", text: $date)
                .accessibilityLabel("Show date, year-month-day")
                .accessibilityIdentifier("tv.plex.date")
                .onSubmit { find() }
            if plex.activity == .searching {
                ProgressView("Searching your library")
                Button("Cancel search") { plex.cancel() }
            } else {
                Button { find() } label: { Label("Find recording", systemImage: "magnifyingglass") }
                    .disabled(!canSearch)
                    .accessibilityIdentifier("tv.plex.search")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30).archivePanel().focusSection()
    }

    private func find() {
        guard canSearch else { return }
        plex.search(date: showDate)
    }

    private func recording(_ match: PlexSearchResult) -> some View {
        let playing = player.isVisible && player.collection == match.collection && player.context == "Plex · \(match.showDate)"
        return LazyVStack(alignment: .leading, spacing: 20) {
            ArchiveScrollingTitle(match.collection).font(.title2.bold())
            Text("\(match.showDate) · Version \(match.version)").font(.callout).foregroundStyle(archive.theme.muted)
            HStack(spacing: 24) {
                Button { plex.play(match, index: 0, with: player) } label: {
                    Label("Play recording", systemImage: "play.fill")
                }
                .accessibilityIdentifier("tv.plex.play")
                if playing {
                    Button { player.isExpanded = true } label: { Label("Now Playing", systemImage: "waveform") }
                        .accessibilityIdentifier("tv.plex.nowPlaying")
                }
            }
            ForEach(Array(match.tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    plex.play(match, index: index, with: player)
                } label: {
                    HStack(spacing: 22) {
                        Text(String(format: "%02d", track.number)).font(.callout.monospacedDigit())
                        ArchiveScrollingTitle(track.title, active: false, restingLines: 2).font(.headline)
                        Spacer()
                        Image(systemName: playing && player.index == index ? "waveform" : "play.fill")
                    }
                    .padding(18).foregroundStyle(archive.theme.text).archivePanel()
                }
                .buttonStyle(.card)
                .accessibilityIdentifier("tv.plex.track.\(index)")
            }
        }
        .padding(14).focusSection()
    }
}
