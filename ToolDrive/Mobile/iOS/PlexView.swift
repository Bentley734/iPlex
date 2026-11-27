import SafariServices
import SwiftUI

struct PlexView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var plex: MobilePlex
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var date = ""
    @State private var confirmDisconnect = false
    @State private var showsPlayer = false

    private var trimmedDate: String { date.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validDate: Bool { (try? PlexParser.searchQueries(showDate: trimmedDate, preferredVersion: nil)) != nil }

    var body: some View {
        NavigationStack {
            List {
                if plex.connected {
                    connection
                    if plex.libraryID != nil { searchForm }
                    if let match = plex.match, match.showDate == trimmedDate, plex.libraryID != nil { recording(match) }
                } else {
                    Section {
                        if plex.activity == .signingIn {
                            ProgressView("Waiting for Plex sign-in")
                            Button("Open Plex sign-in") { plex.reopenSignIn() }
                            Button("Cancel sign-in", role: .cancel) { plex.cancel() }
                        } else {
                            Button("Sign in to Plex", systemImage: "person.crop.circle.badge.checkmark") { plex.signIn() }
                                .accessibilityIdentifier("plex.signIn")
                        }
                    } footer: {
                        Text("Connect a Plex account to stream recordings from a music library on your server.")
                    }
                    .listRowBackground(ArchiveRowBackground())
                }
                if let message = plex.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                        .listRowBackground(ArchiveRowBackground())
                }
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Plex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            .sheet(item: $plex.signInPage) { page in
                PlexSignInBrowser(url: page.url) { plex.signInPage = nil }.ignoresSafeArea()
            }
            .sheet(isPresented: $showsPlayer) { PlayerView().presentationDragIndicator(.visible) }
            .confirmationDialog("Disconnect from Plex?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) {
                    if player.context.hasPrefix("Plex · ") { player.stop() }
                    plex.disconnect()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { plex.open() }
        .onChange(of: player.isVisible) { _, visible in if !visible { showsPlayer = false } }
        .onDisappear {
            if plex.signInPage == nil { plex.cancel() }
        }
    }

    private var connection: some View {
        Section("Connection") {
            if !plex.servers.isEmpty {
                Picker("Server", selection: Binding(get: { plex.serverID ?? "" }, set: plex.selectServer)) {
                    if plex.serverID == nil { Text("Choose server").tag("") }
                    ForEach(plex.servers, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(plex.activity != .idle)
                .accessibilityIdentifier("plex.server")
            }
            if !plex.libraries.isEmpty {
                Picker("Music library", selection: Binding(get: { plex.libraryID ?? "" }, set: plex.selectLibrary)) {
                    if plex.libraryID == nil { Text("Choose library").tag("") }
                    ForEach(plex.libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(plex.activity != .idle)
                .accessibilityIdentifier("plex.library")
            }
            if plex.activity == .servers || plex.activity == .libraries {
                ProgressView(plex.activity == .servers ? "Finding servers" : "Finding music libraries")
            }
            Button("Refresh servers", systemImage: "arrow.clockwise") { plex.refresh() }
                .disabled(plex.activity != .idle)
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private var searchForm: some View {
        Section("Find a recording") {
            TextField("YYYY-MM-DD", text: $date)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel("Show date").accessibilityIdentifier("plex.date")
                .submitLabel(.search).onSubmit { find() }
            if plex.activity == .searching {
                ProgressView("Searching your library")
                Button("Cancel search") { plex.cancel() }
            } else {
                Button("Find recording", systemImage: "magnifyingglass") { find() }
                    .disabled(!validDate || plex.activity != .idle)
                    .accessibilityIdentifier("plex.search")
            }
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private func recording(_ match: PlexSearchResult) -> some View {
        let active = player.isVisible && player.collection == match.collection && player.context == "Plex · \(match.showDate)"
        return Section {
            Button("Play recording", systemImage: "play.fill") { plex.play(match, index: 0, with: player) }
                .accessibilityIdentifier("plex.play")
            if active {
                Button("Now Playing", systemImage: "waveform") { showsPlayer = true }
            }
            ForEach(Array(match.tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    plex.play(match, index: index, with: player)
                } label: {
                    HStack {
                        Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary)
                        ArchiveScrollingTitle(track.title, active: active && player.index == index, restingLines: nil)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: active && player.index == index ? "waveform" : "play").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            ArchiveScrollingTitle("\(match.collection) · Version \(match.version)", active: active, restingLines: nil)
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private func find() {
        guard validDate, plex.activity == .idle else { return }
        plex.search(date: trimmedDate)
    }

    private func close() { plex.cancel(); dismiss() }
}

private struct PlexSignInBrowser: UIViewControllerRepresentable {
    @Environment(\.archiveAccent) private var accent
    let url: URL
    let finished: () -> Void
    @Environment(\.mobileTheme) private var theme
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let finished: () -> Void
        init(_ finished: @escaping () -> Void) { self.finished = finished }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { finished() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        controller.preferredBarTintColor = UIColor(theme.panel)
        controller.preferredControlTintColor = UIColor(accent)
    }
}
