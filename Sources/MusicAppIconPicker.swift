#if os(iOS) || os(tvOS)
import SwiftUI
import UIKit

struct MusicAppIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var changingIcon = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("App Icon").font(.title.bold())
            choices
            .disabled(changingIcon || !UIApplication.shared.supportsAlternateIcons)
            if let message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !UIApplication.shared.supportsAlternateIcons {
                Text("Alternate icons are unavailable on this device.").foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .disabled(changingIcon)
        }
        .padding(24)
    }

    @ViewBuilder private var choices: some View {
        #if os(iOS)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 12) {
            originalChoices
            option("Prismatic Note Light", preview: "prismatic-note-preview", icon: "PrismaticNote")
            option("Prismatic Note Dark", preview: "prismatic-note-dark-preview", icon: "PrismaticNoteDark")
        }
        #else
        HStack(spacing: 20) { originalChoices }
        #endif
    }

    @ViewBuilder private var originalChoices: some View {
        option("Copper Groove", preview: "groove-preview", icon: nil)
        option("Classic Click Wheel", preview: "clickwheel-preview", icon: "ClassicClickWheel")
    }

    private func option(_ title: String, preview: String, icon: String?) -> some View {
        let selected = icon == currentIcon
        return Button {
            guard !selected else { return }
            changingIcon = true
            message = nil
            Task {
                defer { changingIcon = false }
                do {
                    try await UIApplication.shared.setAlternateIconName(icon)
                    currentIcon = icon
                } catch {
                    message = "The app icon couldn’t be changed. Try again."
                }
            }
        } label: {
            VStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: preview, withExtension: "png"),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                }
                Text(title).multilineTextAlignment(.center)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
