import SwiftUI

enum CatalogSort: String, CaseIterable, Identifiable {
    case highest = "Top rated"
    case newest = "Newest first"
    case oldest = "Oldest first"
    case venue = "Venue A–Z"
    var id: Self { self }
}

struct CatalogMatch: Identifiable {
    let show: Concert
    let rating: Double?
    var id: Int { show.id }
}

struct CatalogFilters: Equatable {
    enum Rating: String, CaseIterable, Identifiable {
        case all = "Any", rated = "Rated", unrated = "Unrated"
        var id: Self { self }
    }

    var type = "all"
    var rating: Rating = .all
    var minimum = 0
    var firstYear: Int?
    var lastYear: Int?

    var activeCount: Int {
        [type != "all", rating != .all || minimum > 0, firstYear != nil || lastYear != nil]
            .filter { $0 }.count
    }

    func matches(_ shows: [Concert], query: String, savedOnly: Bool, savedIDs: Set<Int>, sort: CatalogSort) -> [CatalogMatch] {
        let text = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "œ", with: "oe")
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [CatalogMatch] = []
        for show in shows {
            guard !savedOnly || savedIDs.contains(show.id),
                  firstYear.map({ show.year >= $0 }) ?? true, lastYear.map({ show.year <= $0 }) ?? true else { continue }
            let sourceTokens = tokens.filter { !show.searchText.contains($0) }
            var found = false
            var best: Double?
            for source in show.sources {
                guard source.status == "OTD", (type == "all" || type == source.recordingType),
                      sourceTokens.allSatisfy({ source.searchText.contains($0) }) else { continue }
                let score = source.rating.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
                if let score {
                    guard rating != .unrated, score >= Double(minimum) else { continue }
                    best = max(best ?? score, score)
                } else if rating == .rated || (minimum > 0 && rating != .unrated) {
                    continue
                }
                found = true
            }
            if found { result.append(CatalogMatch(show: show, rating: best)) }
        }
        return result.sorted { a, b in
            switch sort {
            case .highest:
                if a.rating != b.rating { return (a.rating ?? -1) > (b.rating ?? -1) }
            case .venue:
                let order = a.show.venue.localizedCaseInsensitiveCompare(b.show.venue)
                if order != .orderedSame { return order == .orderedAscending }
            case .oldest:
                if a.show.date != b.show.date { return a.show.date < b.show.date }
            case .newest: break
            }
            if a.show.date != b.show.date { return a.show.date > b.show.date }
            return a.id < b.id
        }
    }
}

#if os(iOS) && !LEGACY_IOS
struct CatalogFilterSheet: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Binding var filters: CatalogFilters
    let years: [Int]
    let types: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording") {
                    Picker("Recording type", selection: $filters.type) {
                        Text("All types").tag("all")
                        ForEach(types, id: \.self) { type in
                            Text(type == "fm" ? "FM" : type.prefix(1).uppercased() + type.dropFirst()).tag(type)
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("Sound rating") {
                    Picker("Rating availability", selection: $filters.rating) {
                        ForEach(CatalogFilters.Rating.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if filters.rating != .unrated {
                        Stepper(value: $filters.minimum, in: 0...10) {
                            LabeledContent("Minimum", value: filters.minimum == 0 ? "Any" : "\(filters.minimum) / 10")
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("Show years") {
                    Picker("From", selection: $filters.firstYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.lastYear.map { year <= $0 } ?? true }, id: \.self) { year in
                            Text(String(year)).tag(Optional(year))
                        }
                    }
                    Picker("Through", selection: $filters.lastYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.firstYear.map { year >= $0 } ?? true }, id: \.self) { year in
                            Text(String(year)).tag(Optional(year))
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section {
                    Button("Clear all filters") {
                        filters = CatalogFilters()
                    }
                    .disabled(filters.activeCount == 0)
                }
                .listRowBackground(ArchiveRowBackground())
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif

enum HomeShortcut: String, Codable, CaseIterable, Identifiable {
    case saved, filters, random, onThisDay, library
    #if os(tvOS)
    static let configurable = allCases.filter { $0 != .filters }
    #else
    static let configurable = allCases
    #endif
    var id: Self { self }
    var title: String {
        switch self {
        case .saved: "Saved Shows"
        case .filters: "Filters"
        case .random: "Pick a Show"
        case .onThisDay: "On This Day"
        case .library: "Library"
        }
    }
    func label(savedOnly: Bool, activeFilters: Int) -> String {
        if self == .saved && savedOnly { return "All Shows" }
        if self == .filters && activeFilters > 0 { return "Filters · \(activeFilters)" }
        return title
    }

    var icon: String {
        switch self {
        case .saved: "bookmark"
        case .filters: "line.3.horizontal.decrease"
        case .random: "shuffle"
        case .onThisDay: "calendar"
        case .library: "books.vertical"
        }
    }
}

struct HomeScreenPreferences: Codable, Equatable {
    enum Start: String, Codable, CaseIterable { case all = "All Shows", saved = "Saved Shows", library = "Library" }
    enum Density: String, Codable, CaseIterable { case compact = "Compact", roomy = "Roomy" }
    enum Logo: String, Codable, CaseIterable {
        case hidden = "Hidden", small = "Small", medium = "Medium", large = "Large", xl = "XL", xxl = "2XL"

        var scale: CGFloat {
            switch self {
            case .hidden: 0
            case .small: 0.72
            case .medium: 1
            case .large: 1.32
            case .xl: 1.75
            case .xxl: 2.2
            }
        }
    }
    enum Framing: String, Codable, CaseIterable { case automatic = "Original", center = "Center", top = "Top", bottom = "Bottom" }

    var pins: [HomeShortcut] = []
    var start: Start = .all
    var density: Density = .roomy
    var logo: Logo = .medium
    var showStats = false
    var sort = CatalogSort.highest.rawValue
    var framing: Framing = .automatic
    var dimming = 55

    var catalogSort: CatalogSort { CatalogSort(rawValue: sort) ?? .highest }
}

#if !LEGACY_IOS
enum LogoPlacement: String, CaseIterable, Identifiable {
    case home = "Home", topBar = "Top Bar"
    var id: Self { self }
}

struct LogoPlacementControls: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Binding var placement: LogoPlacement

    var body: some View {
        Picker("Logo placement", selection: $placement) {
            ForEach(LogoPlacement.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("appearance.logoPlacement")

        Picker("\(placement.rawValue) logo size", selection: placement == .home ? $archive.home.logo : $archive.topBarLogoSize) {
            ForEach(HomeScreenPreferences.Logo.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .accessibilityIdentifier("appearance.brandLogoSize")
    }
}

struct OnThisDayCard: View {
    @EnvironmentObject private var archive: ArchiveStore
    let open: (Concert) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let anniversary = archive.anniversaryShow(on: context.date) {
                let show = anniversary.show
                Button { open(show) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "calendar")
                            .font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("On This Day").font(.caption.weight(.semibold))
                            Text(show.venue.isEmpty ? "Unknown venue" : show.venue).font(.headline)
                                .lineLimit(1)
                            let age = anniversary.yearsAgo == 1 ? "1 year ago today" : "\(anniversary.yearsAgo) years ago today"
                            let date = [show.dateLabel, age, show.location].filter { !$0.isEmpty }.joined(separator: " · ")
                            Text(date).font(.caption).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("catalog.onThisDay")
                #if os(tvOS)
                .buttonStyle(TVActionStyle())
                #else
                .foregroundStyle(archive.theme.text)
                .padding(12)
                .archiveControl()
                .buttonStyle(.plain)
                #endif
            }
        }
    }
}

struct HomeScreenSettings: View {
    @EnvironmentObject private var archive: ArchiveStore
    var body: some View {
        Form {
            Section("Catalog") {
                Picker("Open to", selection: $archive.home.start) {
                    ForEach(HomeScreenPreferences.Start.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Default sort", selection: $archive.home.sort) {
                    ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Show list spacing", selection: $archive.home.density) {
                    ForEach(HomeScreenPreferences.Density.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show archive stats", isOn: $archive.home.showStats)
            }
            Section {
                ForEach(HomeShortcut.configurable) { shortcut in
                    let selected = archive.home.pins.contains(shortcut)
                    Button {
                        if selected { archive.home.pins.removeAll { $0 == shortcut } }
                        else { archive.home.pins.append(shortcut) }
                    } label: {
                        HStack {
                            Label(shortcut.title, systemImage: shortcut.icon)
                            Spacer()
                            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .disabled(!selected && archive.home.pins.count >= 3)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            } header: { Text("Pinned Shortcuts") }
            footer: { Text("Choose up to three shortcuts to show on Home.") }
            Button("Reset Home Screen Settings") { archive.home = HomeScreenPreferences() }
        }
        .navigationTitle("Home Screen")
        .archivePage(wallpaperID: archive.wallpaperID)
    }
}

struct HomeArchiveStats: View {
    @EnvironmentObject private var archive: ArchiveStore

    var body: some View {
        let rated = archive.shows.reduce(0) { sum, show in
            sum + show.sources.filter { ($0.rating ?? 0) > 0 }.count
        }
        let years = archive.shows.map(\.year).filter { $0 > 0 }
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("On-drive shows", value: archive.shows.count.formatted())
            LabeledContent("Recordings", value: archive.onDriveCount.formatted())
            LabeledContent("Rated recordings", value: rated.formatted())
            if let first = years.min(), let last = years.max() {
                LabeledContent("Years", value: "\(String(first))–\(String(last))")
            }
        }
        .font(.footnote)
        .foregroundStyle(archive.theme.muted)
        .padding(14)
        .archiveControl()
    }
}

struct HomeCatalogUpdates: View {
    @EnvironmentObject private var archive: ArchiveStore
    var body: some View {
        Form {
            Section("Catalog") {
                if !archive.snapshotDate.isEmpty { LabeledContent("Snapshot", value: archive.snapshotDate) }
                if !archive.updateMessage.isEmpty { Text(archive.updateMessage) }
                if archive.updating {
                    ProgressView()
                    Button("Cancel") { archive.cancelUpdate() }
                } else {
                    Button("Check for Catalog Updates") { Task { await archive.refresh() } }
                        .disabled(archive.isLoading || archive.shows.isEmpty)
                }
            }
        }
        .navigationTitle("Updates")
        .archivePage(wallpaperID: archive.wallpaperID)
    }
}
#endif
