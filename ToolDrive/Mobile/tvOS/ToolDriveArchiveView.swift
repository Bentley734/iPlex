import SwiftUI

public struct ToolDriveArchiveView: View {
    private let appearance: IPlexArchiveAppearance
    private let pauseOutsidePlayback: () -> Void

    public init(title: String, text: Color, accent: Color, tint: Color?, density: Double,
                pauseOutsidePlayback: @escaping () -> Void) {
        appearance = IPlexArchiveAppearance(title: title, text: text, accent: accent, tint: tint, density: density)
        self.pauseOutsidePlayback = pauseOutsidePlayback
    }
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var archive = ArchiveStore()
    @StateObject private var player = AudioPlayer()
    @StateObject private var library = MobileLibrary(directory: URL.cachesDirectory.appending(path: "Recordings", directoryHint: .isDirectory))
    @StateObject private var downloads = TVLibraryTransfers()
    @StateObject private var plex = MobilePlex()

    public var body: some View {
            TVCatalogView()
                .environmentObject(archive)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(plex)
                .environment(\.iplexArchiveAppearance, appearance)
                .environment(\.mobileTheme, .liquidGlass)
                .environment(\.mobileGlassControls, true)
                .environment(\.archiveAccent, appearance.accent)
                .environment(\.glassOpacity, GlassOpacity(Int(appearance.density * 100)))
                .tint(appearance.accent)
                .task {
                    player.onShowCompleted = { [weak archive] id in archive?.markListened(id) }
                    await archive.load()
                }
                .onChange(of: player.phase) { _, phase in
                    if phase == .playing { pauseOutsidePlayback() }
                }
                .onDisappear { player.pause(); player.saveProgress(force: true) }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.saveProgress(force: true) }
                }
    }
}

private enum TVRoute: Hashable {
    case show(Int), library, recentlyListened, menu, plex, about, home, stats, updates, albums, songs
}

private struct TVCatalogView: View {
    @Environment(\.iplexArchiveAppearance) private var appearance
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var plex: MobilePlex
    @State private var query = ""
    @State private var savedOnly = false
    @State private var filters = CatalogFilters()
    @State private var started = false
    @State private var path: [TVRoute] = []
    @State private var showingFilters = false
    @State private var noAnniversaryShow = false
    @FocusState private var searchFocused: Bool
    @FocusState private var menuFocused: Bool

    private var searchField: some View {
        HStack(spacing: 12) {
            TextField(
                "Search shows",
                text: $query,
                prompt: Text("Search venues, songs or dates")
                    .foregroundStyle(searchFocused ? Color(white: 0.26) : appearance.muted)
            )
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search shows")
                .accessibilityIdentifier("tv.search")

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(TVActionStyle(iconOnly: true))
                .buttonBorderShape(.circle)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("tv.search.clear")
            }
        }
    }

    var body: some View {
        let matches = filters.matches(archive.shows, query: query, savedOnly: savedOnly, savedIDs: archive.savedIDs, sort: archive.home.catalogSort)
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 60) {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 14) {
                            NavigationLink(value: TVRoute.menu) {
                                Label("Menu", systemImage: "line.3.horizontal")
                            }
                            .accessibilityIdentifier("tv.menu")
                            .focused($menuFocused)
                            Button { useShortcut(.filters, matches: matches) } label: {
                                Label(HomeShortcut.filters.label(savedOnly: savedOnly, activeFilters: filters.activeCount),
                                      systemImage: HomeShortcut.filters.icon)
                            }
                            .accessibilityIdentifier("tv.filters")
                        }
                        .buttonStyle(TVActionStyle())
                        .frame(maxWidth: .infinity)
                        if !archive.home.pins.isEmpty {
                            VStack(spacing: 10) {
                                ForEach(archive.home.pins) { shortcut in
                                    Button { useShortcut(shortcut, matches: matches) } label: {
                                        Label(shortcut.label(savedOnly: savedOnly, activeFilters: filters.activeCount),
                                              systemImage: shortcut.icon)
                                    }
                                    .disabled(shortcut == .random && matches.isEmpty)
                                    .disabled(shortcut == .onThisDay && archive.isLoading)
                                }
                            }
                            .buttonStyle(TVActionStyle())
                            .frame(maxWidth: .infinity)
                        }
                        if player.isVisible {
                            Button { player.isExpanded = true } label: { Label("Now Playing", systemImage: "waveform") }
                                .buttonStyle(TVActionStyle())
                        } else if let saved = player.resumePoint {
                            HStack(spacing: 12) {
                                Button {
                                    Task { await player.resumeLastShow(archive: archive, library: library, plex: plex) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Label("Resume a Show", systemImage: "play.circle.fill")
                                        ArchiveScrollingTitle(saved.title, active: false).font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TVActionStyle())
                                .accessibilityIdentifier("tv.resumeShow")
                                Button {
                                    player.clearResumePoint()
                                    menuFocused = true
                                } label: { Image(systemName: "xmark") }
                                .buttonStyle(TVActionStyle(iconOnly: true))
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Clear saved playback position")
                                .accessibilityIdentifier("tv.clearResumeShow")
                            }
                        }
                        Button { path.append(.recentlyListened) } label: {
                            Label("Recently Listened", systemImage: "clock")
                        }
                        .buttonStyle(TVActionStyle())
                        .accessibilityIdentifier("tv.recentlyListened")
                        Spacer(minLength: 0)
                    }
                    .frame(width: min(625, geometry.size.width * 0.38), alignment: .leading)
                    .focusSection()

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 18) {
                            Text(appearance.title).font(.title.bold())
                                .accessibilityIdentifier("tv.catalog")
                            searchField
                                .padding(.horizontal, 18)
                                .frame(maxWidth: 450, minHeight: 54)
                                .archiveControl()
                            Spacer()
                            if savedOnly && !archive.home.pins.contains(.saved) {
                                Button("All Shows") { savedOnly = false }.buttonStyle(TVActionStyle())
                            }
                            Text(matches.count.formatted()).font(.headline.monospacedDigit()).foregroundStyle(appearance.accent)
                        }
                        if archive.home.showStats { HomeArchiveStats() }
                        OnThisDayCard { path.append(.show($0.id)) }
                        if archive.isLoading && archive.shows.isEmpty {
                            ProgressView("Loading the archive")
                        } else if let error = archive.loadError, archive.shows.isEmpty {
                            Text(error).foregroundStyle(archive.theme.muted)
                        } else if matches.isEmpty {
                            Text(savedOnly ? "Bookmark a show to find it here, or adjust your filters." : "No matching shows. Try a different search or filter.")
                                .foregroundStyle(archive.theme.muted)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: archive.home.density == .compact ? 8 : 16) {
                                    ForEach(matches) { match in
                                        Button { path.append(.show(match.id)) } label: {
                                            TVShowRow(match: match, saved: archive.savedIDs.contains(match.id), compact: archive.home.density == .compact)
                                        }
                                        .buttonStyle(.card)
                                        .accessibilityIdentifier("tv.show.\(match.id)")
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }.focusSection()
                }
            }
            .padding(20)
            .archivePage(wallpaperID: archive.wallpaperID, sharesWindow: true)
            .navigationDestination(for: TVRoute.self) { route in
                switch route {
                case .show(let id):
                    if let show = archive.shows.first(where: { $0.id == id }) { TVShowView(show: show) }
                case .recentlyListened:
                    List {
                        if archive.recentlyListened.isEmpty {
                            Text("Completed shows will appear here.").foregroundStyle(.secondary)
                        }
                        ForEach(archive.recentlyListened) { show in
                            NavigationLink(value: TVRoute.show(show.id)) {
                                VStack(alignment: .leading) {
                                    Text(show.venue.isEmpty ? "Unknown venue" : show.venue)
                                    Text(show.dateLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("Recently Listened")
                case .library:
                    TVLibraryView()
                case .albums:
                    LiveAlbumsView()
                case .songs:
                    ArchiveSongsView { TVShowView(show: $0) }
                case .menu:
                    TVHomeMenu(savedOnly: savedOnly, canPickShow: !matches.isEmpty) { shortcut in
                        path.removeLast()
                        useShortcut(shortcut, matches: matches)
                    }
                case .home: HomeScreenSettings()
                case .updates: HomeCatalogUpdates()
                case .stats:
                    HomeArchiveStats()
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Archive Stats")
                        .archivePage(wallpaperID: archive.wallpaperID)
                case .plex:
                    TVPlexView()
                case .about:
                    TVAboutView()
                }
            }
            .sheet(isPresented: $showingFilters) { TVFiltersView(filters: $filters) }
            .alert("On This Day", isPresented: $noAnniversaryShow) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("No past shows with on-drive recordings match today’s date.")
            }
        }
        .fullScreenCover(isPresented: $player.isExpanded) { TVPlayerView() }
        .onAppear {
            guard !started else { return }
            started = true
            savedOnly = archive.home.start == .saved
            if archive.home.start == .library { path = [.library] }
        }
    }

    private func useShortcut(_ shortcut: HomeShortcut, matches: [CatalogMatch]) {
        switch shortcut {
        case .saved: savedOnly.toggle()
        case .filters: showingFilters = true
        case .random: if let show = matches.randomElement() { path.append(.show(show.id)) }
        case .onThisDay:
            if let anniversary = archive.anniversaryShow() { path.append(.show(anniversary.show.id)) }
            else { noAnniversaryShow = true }
        case .library: path.append(.library)
        }
    }
}

private struct TVHomeMenu: View {
    @EnvironmentObject private var archive: ArchiveStore
    let savedOnly: Bool
    let canPickShow: Bool
    let use: (HomeShortcut) -> Void

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 64) {
                VStack(alignment: .leading, spacing: 18) {
                    heading("Browse")
                    ForEach(HomeShortcut.configurable) { shortcut in
                        Button { use(shortcut) } label: {
                            Label(shortcut.label(savedOnly: savedOnly, activeFilters: 0), systemImage: shortcut.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(shortcut == .random && !canPickShow)
                        .disabled(shortcut == .onThisDay && archive.isLoading)
                    }
                    Picker("Sort Shows", selection: $archive.home.sort) {
                        ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    link("Albums", icon: "opticaldisc", route: .albums)
                    link("Songs", icon: "music.note.list", route: .songs)
                    link("Archive Stats", icon: "chart.bar", route: .stats)
                }.focusSection()
                VStack(alignment: .leading, spacing: 18) {
                    heading("Settings")
                    link("Home Screen", icon: "rectangle.grid.1x2", route: .home)
                    link("Plex", icon: "server.rack", route: .plex)
                    link("Updates", icon: "arrow.triangle.2.circlepath", route: .updates)
                    link("About", icon: "info.circle", route: .about)
                }.focusSection()
            }
            .buttonStyle(TVActionStyle())
            .padding(.horizontal, 100).padding(.vertical, 36)
            .frame(maxWidth: 1420).frame(maxWidth: .infinity)
        }
        .navigationTitle("Menu")
        .archivePage(wallpaperID: archive.wallpaperID)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader).padding(.bottom, 3)
    }

    private func link(_ title: String, icon: String, route: TVRoute) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVArtworkHeader: View {
    @Environment(\.glassOpacity) private var opacity
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.accessibilityReduceTransparency) private var solid
    let title: String
    let subtitle: String
    var centersBrand = false
    private var logoSize: HomeScreenPreferences.Logo { centersBrand ? archive.home.logo : .medium }

    private var subtitleLabel: some View {
        Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
    }

    var body: some View {
        ZStack(alignment: centersBrand ? .center : .bottomLeading) {
            if solid {
                archive.theme.panel
            } else if archive.theme != .liquidGlass {
                ArchiveThemeArtwork(theme: archive.theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
            }
            LinearGradient(colors: [.black.opacity(opacity.amount(0.10, min: 0.04, max: 0.75)),
                                    .black.opacity(opacity.amount(0.28, min: 0.14, max: 0.87)),
                                    .black.opacity(opacity.amount(0.91, min: 0.77, max: 0.98))],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: centersBrand ? .center : .leading, spacing: 8) {
                if logoSize != .hidden {
                    ArchiveBrandLogo(logo: archive.logo)
                        .foregroundStyle(.white)
                        .frame(height: (archive.logo.usesThemeTint ? (centersBrand ? 45 : 52) : (centersBrand ? 61 : 78)) * logoSize.scale)
                        .frame(maxWidth: (archive.logo.usesThemeTint ? (centersBrand ? 166 : 195) : (centersBrand ? 222 : 262)) * logoSize.scale)
                        .accessibilityLabel("TOOL, " + archive.logo.title + " logo")
                        .padding(.bottom, 4)
                }
                Group {
                    if centersBrand { Text(title).lineLimit(2) } else { ArchiveScrollingTitle(title) }
                }.font(.title.bold()).foregroundStyle(.white)
                if !subtitle.isEmpty { subtitleLabel }
            }
            .multilineTextAlignment(centersBrand ? .center : .leading)
            .padding(centersBrand ? 18 : 28)
        }
        .clipShape(RoundedRectangle(cornerRadius: archive.theme.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv.header.logo." + archive.logo.rawValue)
    }
}

private struct TVShowRow: View {
    @Environment(\.archiveAccent) private var accent
    @Environment(\.mobileTheme) private var theme
    let match: CatalogMatch
    let saved: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(match.show.dateLabel).font(.caption.weight(.semibold)).foregroundStyle(accent)
                ArchiveScrollingTitle(match.show.venue.isEmpty ? "Unknown venue" : match.show.venue, active: false)
                    .font(.headline).foregroundStyle(theme.text)
                Text(match.show.location).font(.callout).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            if saved { Image(systemName: "bookmark.fill").foregroundStyle(accent).accessibilityLabel("Saved") }
            if let score = match.rating {
                Label(score.formatted(.number.precision(.fractionLength(0...1))), systemImage: "star.fill")
                    .font(.caption).foregroundStyle(theme.muted)
                    .accessibilityLabel("Rating \(score.formatted()) out of ten")
            }
            Image(systemName: "chevron.right").foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 24).padding(.vertical, compact ? 8 : 15)
        .archivePanel()
        .accessibilityElement(children: .combine)
    }
}

struct TVActionStyle: PrimitiveButtonStyle {
    @EnvironmentObject private var archive: ArchiveStore
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        if archive.theme == .oledDark || archive.glassAccent.usesLightInk {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(TVAccentButtonStyle(
                    surface: archive.theme == .oledDark && archive.glassAccent != .black ? .liquidGlass : archive.glassAccent,
                    ink: archive.theme == .oledDark ? archive.resolvedAccent : .white,
                    iconOnly: iconOnly
                ))
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.foregroundStyle(archive.theme.ink)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct TVAccentSurface: View {
    @Environment(\.mobileTheme) private var theme
    let accent: GlassAccent

    var body: some View {
        if accent == .liquidGlass {
            GeometryReader { geometry in
                Color.clear.archiveControl(cornerRadius: min(geometry.size.width, geometry.size.height) / 2)
            }
        } else {
            Capsule().fill(accent == .black ? .black : accent == .original ? theme.accent : accent.color)
        }
    }
}

private struct TVAccentButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let surface: GlassAccent
    let ink: Color
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .shadow(color: .black.opacity(0.8), radius: 1)
            .padding(.horizontal, iconOnly ? 0 : 26).padding(.vertical, 10)
            .frame(minWidth: iconOnly ? 68 : nil, minHeight: iconOnly ? 68 : 60)
            .background { TVAccentSurface(accent: surface) }
            .overlay {
                Capsule().strokeBorder(.white.opacity(focused ? 1 : 0.48), lineWidth: focused ? 4 : 1)
            }
            .contentShape(Capsule())
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.98 : focused ? 1.045 : 1)
            .opacity(enabled ? 1 : 0.5)
    }
}

private struct TVShowView: View {
    @Environment(\.iplexArchiveAppearance) private var appearance
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var downloads: TVLibraryTransfers
    @EnvironmentObject private var plex: MobilePlex
    let show: Concert

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 58) {
                VStack(alignment: .leading, spacing: 26) {
                    TVArtworkHeader(title: show.venue.isEmpty ? "Unknown venue" : show.venue,
                                    subtitle: [show.dateLabel, show.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .frame(minHeight: 330)
                    Button {
                        archive.toggleSaved(show.id)
                    } label: {
                        Label(archive.savedIDs.contains(show.id) ? "Remove saved show" : "Save show",
                              systemImage: archive.savedIDs.contains(show.id) ? "bookmark.fill" : "bookmark")
                    }
                    Button {
                        archive.toggleListened(show.id)
                    } label: {
                        let listened = archive.listenedIDs.contains(show.id)
                        Label(listened ? "Mark as Unlistened" : "Mark as Listened",
                              systemImage: listened ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityIdentifier("tv.toggleListened")
                    if !show.tour.isEmpty { Text(show.tour).font(.headline) }
                    if !show.setlist.isEmpty {
                        Text("Setlist").font(.title3.bold())
                        ForEach(Array(show.setlist.enumerated()), id: \.offset) { offset, item in
                            HStack(alignment: .firstTextBaseline, spacing: 22) {
                                Text(String(format: "%02d", offset + 1)).font(.caption.monospacedDigit()).foregroundStyle(appearance.muted)
                                ArchiveScrollingTitle(item.title, active: false, restingLines: nil)
                            }.focusable()
                        }
                        if show.setlistOmitted > 0 { Text("\(show.setlistOmitted) additional entries omitted").font(.caption) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()

                VStack(alignment: .leading, spacing: 24) {
                    Text("Recordings").font(.title.bold())
                    CompareRecordings(show: show, saveState: { source in
                        let saved = library.records.contains { $0.key == TVLibraryTransfers.key(show, source) }
                        return (saved ? "Saved Offline" : downloads.preparing == source.id ? "Preparing…" : "Save Offline",
                                !saved && downloads.preparing == nil && library.activity == nil,
                                downloads.lastSource == source.id ? downloads.message : nil)
                    }) { source in
                        downloads.save(show: show, source: source, to: library)
                    }
                    if show.sources.isEmpty { Text("No recording sources are listed.") }
                    ForEach(show.sources) { source in
                        VStack(alignment: .leading, spacing: 14) {
                            Text([source.version, source.recordingType.capitalized].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.headline)
                            Text(["On the drive", source.codec.uppercased(), source.length]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(appearance.muted)
                            if let rating = source.rating { Text("Sound rating \(rating.formatted()) / 10").font(.caption) }
                            if !source.taper.isEmpty { Text("Taper · " + source.taper).font(.caption) }
                            if !source.gear.isEmpty { Text("Equipment · " + source.gear).font(.caption) }
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                                GridRow {
                                    if source.streamVersion != nil && plex.connected && plex.serverID != nil {
                                        PlexStreamButton(show: show, source: source)
                                            .accessibilityIdentifier("tv.plex.source.\(source.id)")
                                    }
                                    if source.streamVersion != nil {
                                        Button { player.stream(show: show, source: source) } label: {
                                            let active = player.isStreaming(source, fromPlex: false) && player.phase != .failed
                                            Label(active ? "Now Playing" : "Stream", systemImage: "play.fill")
                                        }.accessibilityIdentifier("tv.stream.\(source.id)")
                                    }
                                }
                                if source.streamVersion != nil {
                                    GridRow {
                                        NavigationLink(value: TVRoute.library) {
                                            Label("Open library", systemImage: "books.vertical")
                                        }
                                        .accessibilityIdentifier("tv.openLibrary.\(source.id)")
                                        Button {
                                            downloads.save(show: show, source: source, to: library)
                                        } label: {
                                            let saved = library.records.contains { $0.key == TVLibraryTransfers.key(show, source) }
                                            Label(saved ? "Saved offline" : "Save stream offline", systemImage: saved ? "checkmark.circle" : "arrow.down.circle")
                                        }
                                        .accessibilityIdentifier("tv.save.\(source.id)")
                                        .disabled(downloads.preparing != nil || library.activity != nil ||
                                                  library.records.contains { $0.key == TVLibraryTransfers.key(show, source) })
                                    }
                                }
                            }
                            if source.streamVersion != nil {
                                if downloads.preparing == source.id {
                                    ProgressView("Finding tracks")
                                } else if downloads.lastSource == source.id {
                                    Text(downloads.message ?? library.activity.map { "Saving “" + $0 + "” to Library." } ?? library.message)
                                        .font(.caption).foregroundStyle(appearance.muted)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(28).archivePanel()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            }
            .padding(18)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .onAppear { plex.open() }
    }
}

private struct TVFiltersView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: CatalogFilters

    var body: some View {
        let years = Set(archive.shows.map(\.year).filter { $0 > 0 }).sorted()
        let types = Set(archive.shows.flatMap { $0.sources.map(\.recordingType) }.filter { !$0.isEmpty }).sorted()
        NavigationStack {
            Form {
                Section("Catalog") {
                    Picker("Recording type", selection: $filters.type) {
                        Text("All types").tag("all")
                        ForEach(types, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Sound quality") {
                    Picker("Rating availability", selection: $filters.rating) {
                        ForEach(CatalogFilters.Rating.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if filters.rating != .unrated {
                        Picker("Minimum rating", selection: $filters.minimum) {
                            Text("Any").tag(0)
                            ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                        }
                    }
                }
                Section("Show years") {
                    Picker("From", selection: $filters.firstYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.lastYear.map { year <= $0 } ?? true }, id: \.self) { Text(String($0)).tag(Optional($0)) }
                    }
                    Picker("Through", selection: $filters.lastYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.firstYear.map { year >= $0 } ?? true }, id: \.self) { Text(String($0)).tag(Optional($0)) }
                    }
                }
                Button("Clear filters") { filters = CatalogFilters() }
                Button("Done") { dismiss() }
            }
            .navigationTitle("Filters")
            .archivePage(wallpaperID: archive.wallpaperID)
        }
    }
}
