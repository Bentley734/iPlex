import SwiftUI
import UIKit

struct MobileAppIconPicker: View {
    @Environment(\.archiveAccent) private var accent
    @Environment(\.mobileTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var current: String?
    @State private var changing = false
    @State private var available = false
    @State private var errorMessage: String?

    private static let choices = ["Multicolor", "Marbled", "Spectrum", "Block", "Sawblade",
                                  "Classic", "2006", "Opiate", "Opiate2", "FearInoculum",
                                  "Reflection", "Framed", "Orbit", "Static", "Erosion", "Afterimage",
                                  "LightTrail", "Flare", "BlueMist", "1992", "Aenima", "Bone"]

    private func title(for name: String) -> String {
        switch name {
        case "Opiate2": return MobileLogo.opiate2.title
        case "FearInoculum": return MobileLogo.fearInoculum.title
        case "LightTrail": return MobileLogo.lightTrail.title
        case "BlueMist": return MobileLogo.blueMist.title
        case "Aenima": return MobileLogo.aenima.title
        default: return name
        }
    }

    // Picker thumbnails are standalone bundle resources, including on Apple TV.
    private static let previews = Dictionary(uniqueKeysWithValues: choices.compactMap { name -> (String, UIImage)? in
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ToolDrive/IconPreviews"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return (name, image)
    })

    #if os(tvOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 5)
    private let prefix = "tv.icon."
    #else
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 130 : 90, maximum: 200), spacing: 14)]
    }
    private let prefix = "appearance.icon."
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App icon").font(.title3.bold()).foregroundStyle(theme.text)
                .accessibilityAddTraits(.isHeader)
            if available {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(Self.choices, id: \.self) { name in
                        let iconName = name == "Multicolor" ? nil : name
                        let selected = current == iconName
                        Button { change(to: iconName) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(uiImage: Self.previews[name] ?? UIImage())
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(selected ? accent : theme.line,
                                                          lineWidth: selected ? 3 : 1)
                                    }
                                HStack(spacing: 5) {
                                    Text(title(for: name)).font(.subheadline.weight(.semibold))
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                    }
                                }
                                .foregroundStyle(theme.text)
                                #if os(tvOS)
                                .padding([.horizontal, .bottom], 12)
                                #endif
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            #if os(tvOS)
                            .background(theme.panel)
                            #endif
                            .contentShape(Rectangle())
                        }
                        #if os(tvOS)
                        .buttonStyle(.card)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .disabled(changing)
                        .accessibilityLabel(title(for: name))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier(prefix + name)
                    }
                }
            } else {
                Text("Home Screen icon changes are unavailable on this device.")
                    .font(.callout).foregroundStyle(theme.muted)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(theme.text)
                    .accessibilityIdentifier(prefix + "error")
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        available = UIApplication.shared.supportsAlternateIcons
        current = UIApplication.shared.alternateIconName
    }

    private func change(to name: String?) {
        guard !changing, available, name != UIApplication.shared.alternateIconName else { return }
        changing = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(name)
            } catch {
                errorMessage = "Couldn’t change the app icon. " + error.localizedDescription
            }
            refresh()
            changing = false
        }
    }
}
