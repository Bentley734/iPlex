import SwiftUI

struct HeaderAppearanceSettings: View {
    @ObservedObject var library: LibraryModel
    @MusicAppearance private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var section = HeaderBrandSection.music

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Header Logos & Wordmarks").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            Picker("Customize Header For", selection: $section) {
                ForEach(HeaderBrandSection.allCases) { section in
                    Text(library.sectionName(section)).tag(section)
                }
            }
            HeaderAppearanceEditor(section: section, theme: theme) { dismiss() }
                .id(section)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 660, height: 690)
        #elseif os(tvOS)
        .frame(width: 1100, height: 850)
        .onExitCommand { dismiss() }
        #endif
        .musicSheet(theme)
        .tint(theme.accent)
    }
}

private struct HeaderAppearanceEditor: View {
    let section: HeaderBrandSection
    let theme: MusicTheme
    let finish: () -> Void
    private var choices: HeaderBrandChoices
    @AppStorage(HeaderMarkSize.preferenceKey) private var savedSize = HeaderMarkSize.medium
    @State private var logo = HeaderMark.none
    @State private var wordmark = HeaderWordmark.iplex
    @State private var size = HeaderMarkSize.medium
    @State private var gallery = Gallery.logos

    private enum Gallery: String, CaseIterable, Identifiable {
        case logos = "Logos", wordmarks = "Wordmarks"
        var id: Self { self }
    }

    init(section: HeaderBrandSection, theme: MusicTheme, finish: @escaping () -> Void) {
        self.section = section
        self.theme = theme
        self.finish = finish
        choices = HeaderBrandChoices(section: section)
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.adaptive(minimum: 230), spacing: 18)]
        #else
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview").font(.headline)
                HeaderBrand(theme: theme, width: 280, height: 64, allowsCycling: false,
                            section: section, mark: $logo, wordmark: $wordmark, previewMarkSize: size)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Header preview: \(logo.label), \(wordmark.label)")
                Text("Browse options below, then Apply to update this header.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("Preview options", selection: $gallery) {
                ForEach(Gallery.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    if gallery == .logos {
                        ForEach(HeaderMark.choices(for: section)) { option in
                            tile(option.label, selected: logo == option, action: { logo = option }) {
                                if option == .none {
                                    Text("No logo").foregroundStyle(.secondary)
                                } else {
                                    HeaderBrand(theme: theme, width: 116, height: 64, allowsCycling: false,
                                                section: section, mark: .constant(option), wordmark: .constant(.none),
                                                previewMarkSize: .large)
                                }
                            }
                        }
                    } else {
                        ForEach(HeaderWordmark.choices(for: section)) { option in
                            tile(option.label, selected: wordmark == option, action: { wordmark = option }) {
                                if option == .none {
                                    Text("No wordmark").foregroundStyle(.secondary)
                                } else {
                                    HeaderBrand(theme: theme, width: 130, height: 48, allowsCycling: false,
                                                section: section, mark: .constant(.none), wordmark: .constant(option))
                                }
                            }
                        }
                    }
                }.padding(6)
            }
            .id(gallery)
            Picker("Header Logo Size", selection: $size) {
                ForEach(HeaderMarkSize.allCases) { Text($0.label).tag($0) }
            }
            Text("Logo size applies to every header.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Apply") {
                    choices.logoSelection.wrappedValue = logo
                    choices.wordmarkSelection.wrappedValue = wordmark
                    savedSize = size
                    finish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            logo = choices.logoSelection.wrappedValue
            wordmark = choices.wordmarkSelection.wrappedValue
            size = savedSize
        }
    }

    private func tile<Content: View>(_ label: String, selected: Bool, action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                content().frame(height: 70).frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text(label).font(.callout).multilineTextAlignment(.center)
                    .frame(minHeight: 36)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? theme.accent : theme.text.opacity(0.4))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(selected ? theme.accent.opacity(0.15) : theme.text.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? theme.accent : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
