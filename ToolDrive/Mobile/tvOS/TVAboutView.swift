import SwiftUI

struct TVAboutView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("About Tool Drive Offline")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tv.about.done")
                }
                .focusSection()

                HStack(alignment: .top, spacing: 58) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Tool Drive Offline is an unofficial third-party app for the Tool Drive Project at tooldriveproject.net. The project provides the concert catalog and recording details.")
                        Text("This app is not associated with or endorsed by TOOL.")
                            .fontWeight(.semibold)
                        Divider()
                        Text("Archive credits")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("**Geordy and Karl** founded the Tool Drive Project in 2003 to share live recordings with other fans.")
                        Text("**Drew** hosted the website for many years. **Taylor and Jon** helped modernize the site and the way the project distributes the drive.")
                        Text("Thanks to the tapers who recorded these shows, the fans who copied and shared the drives, and the setlist.fm contributors who documented the setlists.")
                        Divider()
                        Text("Visualizer credits").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text("The kaleidoscopes were inspired by Colliding Scopes by Alan (Stereo Drift), gbendy/kaleidoscope, and Ege Çetin’s libKaleidoscope. Mirrored Stage concert photography by Originate Designs Photography.")
                    }
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 18) {
                        Text("Project history and credits")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Image("ProjectAboutCode")
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 246, height: 246)
                            .accessibilityHidden(true)
                        Text("Scan with your phone or visit")
                            .font(.callout)
                            .foregroundStyle(archive.theme.muted)
                        Text(verbatim: "tooldriveproject.net/?page=about")
                            .font(.caption)
                    }
                    .multilineTextAlignment(.center)
                    .frame(width: 388)
                }
                .padding(40)
                .archivePanel()
            }
            .frame(maxWidth: 1560)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .onExitCommand { dismiss() }
    }
}
