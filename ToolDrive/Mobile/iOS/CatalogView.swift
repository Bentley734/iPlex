import SwiftUI
import UIKit

struct CatalogView: View {
    @EnvironmentObject private var store: ArchiveStore
    @EnvironmentObject private var audio: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var plex: MobilePlex
    @Environment(\.iplexArchiveAppearance) private var appearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var savedOnly = false
    @State private var filters = CatalogFilters()
    @State private var started = false
    @State private var selectedID: Int?
    @State private var selectedAnniversary = false
    @State private var noAnniversaryShow = false
    @State private var phonePath: [Int] = []
    @State private var sidebarVisible = true
    @State private var sheet: CatalogSheet?

    @Binding var openRecording: Int?

    init(openRecording: Binding<Int?> = .constant(nil)) {
        _openRecording = openRecording
    }

    private enum CatalogSheet: String, Identifiable {
        case filters, library, plex, about, home, updates, stats, albums, songs
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            archive(width: geometry.size.width)
        }
        .onChange(of: openRecording, initial: true) { _, id in
            guard let id else { return }
            selectedID = id
            selectedAnniversary = true
            phonePath = [id]
            openRecording = nil
        }
        .sheet(isPresented: Binding(
            get: { sheet == nil && audio.isExpanded },
            set: { audio.isExpanded = $0 }
        )) {
            PlayerView().presentationDragIndicator(.visible)
        }
        .alert("On This Day", isPresented: $noAnniversaryShow) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No past shows with on-drive recordings match today’s date.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .filters:
                CatalogFilterSheet(filters: $filters, years: Set(store.shows.map(\.year).filter { $0 > 0 }).sorted(),
                                   types: Set(store.shows.flatMap { $0.sources.map(\.recordingType) }.filter { !$0.isEmpty }).sorted())
            case .library: LibraryView()
            case .plex: PlexView()
            case .about: settingsSheet { ArchiveAboutView() }
            case .home: settingsSheet { HomeScreenSettings() }
            case .updates: settingsSheet { HomeCatalogUpdates() }
            case .albums, .songs:
                NavigationStack {
                    Group {
                        if sheet == .albums { LiveAlbumsView() }
                        else { ArchiveSongsView { ShowDetailView(show: $0) } }
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.sheet = nil } } }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
            case .stats: settingsSheet {
                ScrollView { HomeArchiveStats().padding(18) }
                    .archivePage(wallpaperID: store.wallpaperID).navigationTitle("Archive Stats")
            }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            savedOnly = store.home.start == .saved
            if store.home.start == .library && phonePath.isEmpty && openRecording == nil { sheet = .library }
        }
    }

    private func settingsSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
    }

    private var sort: Binding<String> { $store.home.sort }

    private func archive(width: CGFloat) -> some View {
        let split = UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular && width >= 720
        let matches = filters.matches(store.shows, query: query, savedOnly: savedOnly, savedIDs: store.savedIDs, sort: store.home.catalogSort)
        let selected = selectedAnniversary ? store.shows.first { $0.id == selectedID }
            : (matches.first { $0.id == selectedID } ?? matches.first)?.show
        return Group {
            if split {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        NavigationStack {
                            catalog(matches, highlighted: selected?.id) { show, anniversary in
                                selectedID = show.id
                                selectedAnniversary = anniversary
                            }
                                .toolbar { ToolbarItem(placement: .topBarLeading) { sidebarToggle } }
                        }
                        .frame(width: min(450, max(310, (width / 3).rounded())))
                        Divider()
                    }
                    NavigationStack {
                        Group {
                            if let selected {
                                ShowDetailView(show: selected).id(selected.id)
                            } else if store.isLoading {
                                ProgressView("Loading archive")
                            } else {
                                ContentUnavailableView("No show selected", systemImage: "music.note.list")
                            }
                        }
                        .toolbar {
                            if !sidebarVisible {
                                ToolbarItem(placement: .topBarLeading) { sidebarToggle }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                NavigationStack(path: $phonePath) {
                    catalog(matches, highlighted: nil) { show, anniversary in
                        selectedID = show.id
                        selectedAnniversary = anniversary
                        phonePath = [show.id]
                    }
                    .navigationDestination(for: Int.self) { id in
                        if let show = store.shows.first(where: { $0.id == id }) {
                            ShowDetailView(show: show)
                        } else {
                            ContentUnavailableView("Show unavailable", systemImage: "music.note.list")
                        }
                    }
                }
            }
        }
        .onChange(of: split) { _, isSplit in
            if isSplit {
                if let id = phonePath.last { selectedID = id }
            } else if let selectedID {
                phonePath = [selectedID]
            }
        }
    }

    private var sidebarToggle: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Label(sidebarVisible ? "Hide sidebar" : "Show sidebar", systemImage: "sidebar.leading")
        }
        .accessibilityIdentifier("catalog.sidebar")
    }

    private func catalog(_ matches: [CatalogMatch], highlighted: Int?, open: @escaping (Concert, Bool) -> Void) -> some View {
        List {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                if store.home.showStats { HomeArchiveStats() }
                OnThisDayCard { open($0, true) }
                if let saved = audio.resumePoint, !audio.isVisible {
                    HStack(spacing: 0) {
                        Button {
                            Task { await audio.resumeLastShow(archive: store, library: library, plex: plex) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Resume a Show", systemImage: "play.circle.fill").font(.headline)
                                Text(saved.title + " · " + saved.trackTitle)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("catalog.resumeShow")
                        Button {
                            audio.clearResumePoint()
                        } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear saved playback position")
                        .accessibilityIdentifier("catalog.clearResumeShow")
                    }
                    .buttonStyle(.plain)
                    .archiveControl()
                }
                DisclosureGroup("Recently Listened") {
                    if store.recentlyListened.isEmpty {
                        Text("Completed shows will appear here.").foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(store.recentlyListened) { show in
                        Button { open(show, true) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(show.venue.isEmpty ? "Unknown venue" : show.venue)
                                Text(show.dateLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .archiveControl()
                .accessibilityIdentifier("catalog.recentlyListened")
                if !store.home.pins.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(store.home.pins) { shortcut in
                                shortcutButton(shortcut, matches: matches, open: open)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 10).frame(minHeight: 44)
                                    .archiveControl()
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 9)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            Section {
                if store.isLoading && store.shows.isEmpty {
                    ProgressView("Loading archive")
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .listRowSeparator(.hidden)
                } else if let error = store.loadError, store.shows.isEmpty {
                    ContentUnavailableView("Archive unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .listRowSeparator(.hidden)
                } else if matches.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(matches) { match in
                        Button {
                            open(match.show, false)
                        } label: {
                            CatalogRow(match: match, saved: store.savedIDs.contains(match.id), selected: match.id == highlighted, compact: store.home.density == .compact)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens show details")
                        .accessibilityIdentifier("catalog.show.\(match.id)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 16))
                        .listRowBackground(ArchiveRowBackground(selected: match.id == highlighted))
                        .listRowSeparatorTint(store.theme.line)
                        .swipeActions(edge: .trailing) { saveButton(match) }
                        .contextMenu { saveButton(match) }
                    }
                }
            } header: {
                resultsHeader(matches.count)
            }
        }
        .listStyle(.plain)
        .archivePage(wallpaperID: store.wallpaperID, sharesWindow: true)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(appearance.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Browse") {
                        ForEach(HomeShortcut.allCases) { shortcut in
                            shortcutButton(shortcut, matches: matches, open: open)
                        }
                        Button { sheet = .albums } label: { Label("Albums", systemImage: "opticaldisc") }
                        Button { sheet = .songs } label: { Label("Songs", systemImage: "music.note.list") }
                        Menu {
                            Picker("Sort Shows", selection: sort) {
                                ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                            }
                        } label: { Label("Sort Shows", systemImage: "arrow.up.arrow.down") }
                        Button { sheet = .stats } label: { Label("Archive Stats", systemImage: "chart.bar") }
                    }
                    Section("Settings") {
                        Button { sheet = .home } label: { Label("Home Screen", systemImage: "rectangle.grid.1x2") }
                        Button { sheet = .plex } label: { Label("Plex", systemImage: "server.rack") }
                        Button { sheet = .updates } label: { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                        Button { sheet = .about } label: { Label("About", systemImage: "info.circle") }
                    }
                } label: { Label("Menu", systemImage: "line.3.horizontal").labelStyle(.iconOnly) }
                .accessibilityLabel("Menu").accessibilityIdentifier("catalog.menu")
            }
        }
    }

    private func shortcutButton(_ shortcut: HomeShortcut, matches: [CatalogMatch],
                                open: @escaping (Concert, Bool) -> Void) -> some View {
        Button {
            switch shortcut {
            case .saved: savedOnly.toggle()
            case .filters: sheet = .filters
            case .random: if let show = matches.randomElement() { open(show.show, false) }
            case .onThisDay:
                if let anniversary = store.anniversaryShow() { open(anniversary.show, true) }
                else { noAnniversaryShow = true }
            case .library: sheet = .library
            }
        } label: {
            Label(shortcut.label(savedOnly: savedOnly, activeFilters: filters.activeCount), systemImage: shortcut.icon)
        }
        .disabled(shortcut == .random && matches.isEmpty)
        .disabled(shortcut == .onThisDay && store.isLoading)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search shows", text: $query,
                      prompt: Text("Venue, city, song or date").foregroundStyle(appearance.muted))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search shows")
                .accessibilityIdentifier("catalog.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear search")
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .archiveControl()
    }

    private func resultsHeader(_ count: Int) -> some View {
        HStack {
            Text("\(count.formatted()) \(savedOnly ? "saved " : "")\(count == 1 ? "show" : "shows")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("catalog.resultCount")
            Spacer(minLength: 8)
            if filters.activeCount > 0 && !store.home.pins.contains(.filters) {
                Button { sheet = .filters } label: {
                    Label("Filters · \(filters.activeCount)", systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("catalog.filters")
            }
            if savedOnly && !store.home.pins.contains(.saved) {
                Button("All Shows") { savedOnly = false }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44).buttonStyle(.borderless)
            }
        }
        .textCase(nil)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(savedOnly && store.savedIDs.isEmpty ? "No saved shows" : "No matching shows",
                  systemImage: savedOnly && store.savedIDs.isEmpty ? "bookmark" : "magnifyingglass")
        } description: {
            Text(savedOnly && store.savedIDs.isEmpty ? "Save a show from its details to find it here." : "Try another search or adjust your filters.")
        } actions: {
            if savedOnly && store.savedIDs.isEmpty {
                Button("Browse shows") { savedOnly = false }
            } else {
                Button("Clear search and filters") {
                    query = ""
                    filters = CatalogFilters()
                }
            }
        }
    }

    private func saveButton(_ match: CatalogMatch) -> some View {
        let saved = store.savedIDs.contains(match.id)
        return Button { store.toggleSaved(match.id) } label: {
            Label(saved ? "Remove from Saved" : "Save show", systemImage: saved ? "bookmark.slash" : "bookmark")
        }
        .tint(saved ? .secondary : store.resolvedAccent)
        .accessibilityIdentifier("catalog.save.\(match.id)")
    }
}

private struct CatalogRow: View {
    @Environment(\.archiveAccent) private var accent
    let match: CatalogMatch
    let saved: Bool
    let selected: Bool
    let compact: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.mobileTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(match.show.dateLabel)
                        .font(.system(.caption, design: theme == .nightShift || theme == .laserGrid ? .monospaced : .default, weight: .semibold))
                        .foregroundStyle(theme.muted)
                    if saved {
                        Image(systemName: "bookmark.fill").font(.caption2)
                            .foregroundStyle(accent)
                            .accessibilityLabel("Saved")
                    }
                }
                ArchiveScrollingTitle(match.show.venue, active: selected, restingLines: nil)
                    .font(.headline).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                if !match.show.location.isEmpty {
                    Text(match.show.location).font(.subheadline).foregroundStyle(theme.muted)
                }
                if typeSize.isAccessibilitySize, let score = match.rating { rating(score) }
            }
            Spacer(minLength: 3)
            if !typeSize.isAccessibilitySize, let score = match.rating { rating(score) }
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.vertical, compact ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func rating(_ score: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
            if theme == .nightShift && !typeSize.isAccessibilitySize {
                ArchiveNumberDisplay(value: String(format: "%.1f", score)).frame(height: 15)
            } else {
                Text(score.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .foregroundStyle(accent)
        .background(accent.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound rating \(score.formatted()) out of 10")
    }
}
