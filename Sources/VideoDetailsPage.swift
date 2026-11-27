import SwiftUI

struct PlexVideoCredit {
    let name: String
    let role: String
    let photo: String?
    var id: String? = nil
}

struct PlexVideoDetails {
    let summary: String?
    let year: Int?
    let minutes: Int?
    let classification: String?
    let genres: [String]
    let backdrop: String?
    let thumbnail: String?
    let credits: [PlexVideoCredit]
    let formats: [String]
}

struct VideoDetailsPage<Actions: View, Episodes: View>: View {
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
    @ViewBuilder let episodes: () -> Episodes

    @MusicAppearance private var theme
    @ObservedObject private var downloads = MediaDownloads.shared
    @ObservedObject private var wallpaper = GlassWallpaper.shared
    @State private var requestedDownload = false
    @State private var details: PlexVideoDetails?
    @State private var loadError = false
    @State private var retry = 0
    var onCredit: ((PlexVideoCredit) -> Void)?

    #if os(tvOS)
    @FocusState private var backFocused: Bool
    #endif

    private var isEpisode: Bool { item.type == "episode" }

    private var facts: [String] {
        [isEpisode ? item.subtitle : details?.year.map { String($0) } ?? item.subtitle,
         details?.minutes.map { "\($0) min" } ?? "",
         details?.classification ?? ""].filter { !$0.isEmpty }
    }

    var body: some View {
        layout
        .background {
            if wallpaper.background == .gradient { theme.backdrop }
        }
        .task(id: [section, item.id, String(ready), String(retry)]) {
            guard ready else { return }
            loadError = false
            do {
                let result = try await service.videoDetails(server: server, section: section, item: item)
                if !Task.isCancelled { details = result }
            } catch {
                if !Task.isCancelled { loadError = true }
            }
        }
    }

    @ViewBuilder private var layout: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 20) {
            Button("Back", systemImage: "chevron.backward", action: back)
                .buttonStyle(.bordered)
                .accessibilityLabel("Back to " + sectionName)
                .accessibilityIdentifier("tv.video.back")
                .focused($backFocused)
            HStack(alignment: .top, spacing: 26) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        thumbnail.frame(width: isEpisode ? 240 : 132, height: isEpisode ? 135 : 198)
                            .accessibilityHidden(true)
                        information
                        if requestedDownload && !downloads.status.isEmpty {
                            Text(downloads.status).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 485)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 22))
                .focusSection()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        episodes()
                        let summary = details?.summary ?? item.summary
                        if !summary.isEmpty {
                            sectionPanel("Synopsis") {
                                Text(summary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let details, !details.credits.isEmpty {
                            sectionPanel("Cast and Crew") { credits(details.credits) }
                        }
                        if let details, !details.formats.isEmpty {
                            sectionPanel(details.formats.count == 1 ? "Video Format" : "Video Formats") {
                                ForEach(Array(details.formats.enumerated()), id: \.offset) { _, format in
                                    Text(format).font(.callout.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if loadError {
                            Text("Plex couldn’t load the full details.").foregroundStyle(.secondary)
                            Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusSection()
            }
        }
        .padding(20)
        .defaultFocus($backFocused, true)
        .task { backFocused = true }
        #else
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                Label("Back to " + sectionName, systemImage: "chevron.backward")
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) {
                            thumbnail
                                .frame(width: isEpisode ? 224 : 132, height: isEpisode ? 126 : 198)
                            information.frame(minWidth: 290)
                        }
                        .padding(24)
                        VStack(alignment: .leading, spacing: 16) {
                            if isEpisode {
                                thumbnail.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: 320)
                            }
                            information
                        }.padding(18)
                    }
                    .frame(maxWidth: 750, alignment: .leading)
                    .musicGlass(theme, radius: 20)
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: isEpisode ? 280 : 370, alignment: .bottomLeading)
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
                    episodes()
                    if let details, !details.formats.isEmpty {
                        sectionPanel(details.formats.count == 1 ? "Video Format" : "Video Formats") {
                            ForEach(Array(details.formats.enumerated()), id: \.offset) { _, format in
                                Text(format).font(.callout.monospaced()).foregroundStyle(theme.text.opacity(0.8))
                            }
                        }
                    }
                    if loadError {
                        HStack {
                            Text("Plex couldn’t load the full details.").foregroundStyle(.secondary)
                            Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1380)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        #endif
    }

    private var thumbnail: some View {
        artwork(details?.thumbnail ?? item.thumb, icon: isEpisode ? "tv" : "film")
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
                #if os(tvOS)
                .fixedSize(horizontal: false, vertical: true)
                #else
                .lineLimit(3)
                #endif
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
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 10) { controls }
                .focusSection()
            #else
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            #endif
            if let resume {
                Text("Continue at " + videoTime(resume)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(theme.text)
    }

    @ViewBuilder private var controls: some View {
        if item.type != "show" {
            Button(resume == nil ? (isEpisode ? "Play Episode" : "Play Movie") : "Resume", systemImage: "play.fill", action: play)
                .buttonStyle(.borderedProminent)
                .disabled(!ready)
            Button("Download", systemImage: "arrow.down.circle") {
                requestedDownload = true
                download()
            }
            .buttonStyle(.bordered)
            .disabled(!ready)
        }
        Menu(isEpisode ? "Episode Actions" : item.type == "show" ? "Show Actions" : "Movie Actions", systemImage: "ellipsis.circle", content: actions)
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

    private func credits(_ credits: [PlexVideoCredit]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                    if credit.id != nil, let onCredit {
                        Button { onCredit(credit) } label: { creditCard(credit) }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(.plain)
                            #endif
                    } else {
                        creditCard(credit)
                    }
                }
            }
        }
    }

    private func creditCard(_ credit: PlexVideoCredit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            creditPortrait(credit)
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(credit.name).font(.callout.weight(.semibold)).lineLimit(2)
            if !credit.role.isEmpty {
                Text(credit.role).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        #if os(tvOS)
        .frame(width: 158, alignment: .leading)
        .padding(8)
        #else
        .frame(width: 112, alignment: .leading)
        #endif
    }

    @ViewBuilder private func creditPortrait(_ credit: PlexVideoCredit) -> some View {
        let placeholder = Image(systemName: credit.role == "Director" ? "film" : "person")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.accent.opacity(0.14))
        if let photo = credit.photo {
            if let url = PlexParser.remoteCreditPhoto(photo), ready {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else if photo.hasPrefix("/") {
                artwork(photo, icon: "person.crop.square")
            } else { placeholder }
        } else { placeholder }
    }

    private func artwork(_ path: String?, icon: String, placeholder: Bool = true) -> some View {
        PlexVideoPoster(path: path, server: server, section: section, service: service, icon: icon,
                       cachedOnly: !ready, showPlaceholder: placeholder)
    }
}
