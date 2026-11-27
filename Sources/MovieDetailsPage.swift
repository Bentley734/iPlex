import SwiftUI

struct PlexMovieCredit {
    let name: String
    let role: String
    let photo: String?
}

struct PlexMovieDetails {
    let summary: String?
    let year: Int?
    let minutes: Int?
    let classification: String?
    let genres: [String]
    let backdrop: String?
    let credits: [PlexMovieCredit]
    let formats: [String]
}

struct MovieDetailsPage<Actions: View>: View {
    let item: PlexVideoItem
    let server: String
    let section: String
    let service: PlexService
    let ready: Bool
    let resume: Double?
    let sectionName: String
    let back: () -> Void
    let play: () -> Void
    let download: () -> Void
    @ViewBuilder let actions: () -> Actions

    @MusicAppearance private var theme
    @ObservedObject private var downloads = MediaDownloads.shared
    @State private var requestedDownload = false
    @State private var details: PlexMovieDetails?
    @State private var loadError = false
    @State private var retry = 0

    private var facts: [String] {
        [details?.year.map { String($0) } ?? item.subtitle,
         details?.minutes.map { "\($0) min" } ?? "",
         details?.classification ?? ""].filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button("Back to " + sectionName, systemImage: "chevron.backward", action: back)
                    .buttonStyle(.bordered)
                    #if !os(tvOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        artwork(item.thumb, icon: "film").frame(width: 132, height: 198)
                        information.frame(minWidth: 290)
                    }
                    .padding(24)
                    information.padding(18)
                }
                .frame(maxWidth: 750, alignment: .leading)
                .musicGlass(theme, radius: 20)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 370, alignment: .bottomLeading)
                .background { backdrop }
                .clipShape(.rect(cornerRadius: 24))
                if requestedDownload && !downloads.status.isEmpty {
                    Text(downloads.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                let summary = details?.summary ?? item.summary
                if !summary.isEmpty {
                    sectionPanel("Synopsis") {
                        Text(summary)
                            .foregroundStyle(theme.text.opacity(0.84))
                            .frame(maxWidth: 880, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let details, !details.credits.isEmpty {
                    sectionPanel("Cast and Crew") { credits(details.credits) }
                }
                if let details, !details.formats.isEmpty {
                    sectionPanel(details.formats.count == 1 ? "Video Format" : "Video Formats") {
                        ForEach(Array(details.formats.enumerated()), id: \.offset) { _, format in
                            Text(format).font(.callout.monospaced()).foregroundStyle(theme.text.opacity(0.8))
                        }
                    }
                }
                if loadError {
                    HStack {
                        Text("Plex couldn’t load the full movie details.").foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1380)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: [section, item.id, String(ready), String(retry)]) {
            guard ready else { return }
            loadError = false
            do {
                let result = try await service.movieDetails(server: server, section: section, item: item)
                if !Task.isCancelled { details = result }
            } catch {
                if !Task.isCancelled { loadError = true }
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [theme.accent.opacity(0.36), theme.surface, Color.black.opacity(0.74)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            if let path = details?.backdrop {
                artwork(path, icon: "film", placeholder: false)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            if !facts.isEmpty {
                Text(facts.joined(separator: "  ·  "))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.text.opacity(0.8))
            }
            if let genres = details?.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(theme.text.opacity(0.8))
                    .lineLimit(2)
            }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            if let resume {
                Text("Continue at " + videoTime(resume)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.text)
    }

    @ViewBuilder private var controls: some View {
        Button(resume == nil ? "Play Movie" : "Resume", systemImage: "play.fill", action: play)
            .buttonStyle(.borderedProminent)
            .disabled(!ready)
        Button("Download", systemImage: "arrow.down.circle") {
            requestedDownload = true
            download()
        }
        .buttonStyle(.bordered)
        .disabled(!ready || downloads.busy)
        Menu("Movie Actions", systemImage: "ellipsis.circle", content: actions)
            .disabled(!ready)
    }

    private func sectionPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .musicGlass(theme, radius: 18)
    }

    private func credits(_ credits: [PlexMovieCredit]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                    VStack(alignment: .leading, spacing: 6) {
                        if let photo = credit.photo {
                            artwork(photo, icon: "person.crop.square")
                                .frame(width: 64, height: 64)
                        } else {
                            Image(systemName: credit.role == "Director" ? "film" : "person")
                                .frame(width: 64, height: 64)
                                .background(theme.accent.opacity(0.14), in: .rect(cornerRadius: 12))
                                .accessibilityHidden(true)
                        }
                        Text(credit.name).font(.callout.weight(.semibold)).lineLimit(2)
                        if !credit.role.isEmpty {
                            Text(credit.role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(width: 112, alignment: .leading)
                }
            }
        }
    }

    private func artwork(_ path: String?, icon: String, placeholder: Bool = true) -> some View {
        PlexVideoPoster(path: path, server: server, section: section, service: service, icon: icon,
                       cachedOnly: !ready, showPlaceholder: placeholder)
    }
}
