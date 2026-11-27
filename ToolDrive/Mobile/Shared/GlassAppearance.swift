import SwiftUI

enum GlassAccent: String, CaseIterable {
    case original = "default", aqua, blue, violet, rose, amber, green

    case black, liquidGlass = "liquid-glass"

    var usesLightInk: Bool { self == .black || self == .liquidGlass }

    var title: String {
        if self == .liquidGlass { return "Liquid Glass" }
        return self == .original ? "Original" : rawValue.capitalized
    }
    var color: Color {
        switch self {
        case .original: return MobileTheme.liquidGlass.accent
        case .aqua: return Color(archiveRGB: 0x64ead5)
        case .blue: return Color(archiveRGB: 0x80b7ff)
        case .violet: return Color(archiveRGB: 0xc7a1ff)
        case .rose: return Color(archiveRGB: 0xff9cbc)
        case .amber: return Color(archiveRGB: 0xffd081)
        case .green: return Color(archiveRGB: 0x97e8a3)
        // These accents use a dark or glass button surface. Keep standalone
        // foreground accents (ratings, playback indicators, and checkmarks) legible.
        case .black, .liquidGlass: return .white
        }
    }
}

struct GlassOpacity {
    let percent: Int

    init(_ value: Int = 50) {
        percent = Int((Double(min(max(value, 0), 100)) / 5).rounded()) * 5
    }

    // Each surface keeps its original opacity at the midpoint.
    func amount(_ original: Double, min light: Double, max dense: Double) -> Double {
        let scale = Double(percent - 50) / 50
        return original + scale * (scale < 0 ? original - light : dense - original)
    }
}

#if !LEGACY_IOS
private struct ArchiveAccentKey: EnvironmentKey { static let defaultValue = MobileTheme.frontRow.accent }
private struct GlassOpacityKey: EnvironmentKey { static let defaultValue = GlassOpacity() }
private struct GlassAccentKey: EnvironmentKey { static let defaultValue = GlassAccent.original }

extension EnvironmentValues {
    var archiveAccent: Color {
        get { self[ArchiveAccentKey.self] }
        set { self[ArchiveAccentKey.self] = newValue }
    }
    var glassOpacity: GlassOpacity {
        get { self[GlassOpacityKey.self] }
        set { self[GlassOpacityKey.self] = newValue }
    }
    var archiveGlassAccent: GlassAccent {
        get { self[GlassAccentKey.self] }
        set { self[GlassAccentKey.self] = newValue }
    }
}

#if os(iOS)
private struct ArchivePrimarySurface: ViewModifier {
    @Environment(\.mobileTheme) private var theme
    @Environment(\.archiveAccent) private var color
    @Environment(\.archiveGlassAccent) private var accent
    let radius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme.usesGlass && accent == .liquidGlass {
            content.foregroundStyle(.white).archiveControl(cornerRadius: radius)
        } else if theme.usesGlass && accent == .black {
            content.foregroundStyle(.white).background(.black, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.45)).allowsHitTesting(false) }
        } else {
            content.foregroundStyle(theme.ink).background(color, in: shape)
        }
    }
}

extension View {
    func archivePrimarySurface(cornerRadius: CGFloat) -> some View {
        modifier(ArchivePrimarySurface(radius: cornerRadius))
    }
}
#endif

struct GlassAppearanceControls: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(tvOS)
    var moveBelowSlider: () -> Void
    @FocusState private var focusedSlider: Bool
    @FocusState private var focusedAccent: GlassAccent?
    private let prefix = "tv.glass."
    #else
    private let prefix = "appearance.glass."
    #endif

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 22), count: 5)
        #else
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 135 : 96), spacing: 10)]
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accent color").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(GlassAccent.allCases, id: \.self) { color in
                    let selected = color == archive.glassAccent
                    let swatchColor = color == .original ? archive.theme.accent : color.color
                    Button { archive.selectGlassAccent(color) } label: {
                        HStack(spacing: 7) {
                            #if os(tvOS)
                            TVAccentSurface(accent: color)
                                .overlay {
                                    if color.usesLightInk { Circle().strokeBorder(.white.opacity(0.65)) }
                                    if selected {
                                        Image(systemName: "checkmark").font(.caption.bold())
                                            .foregroundStyle(color.usesLightInk ? .white : .black)
                                    }
                                }
                                .frame(width: swatchSize, height: swatchSize)
                            #else
                            Circle().fill(color == .black ? .black : swatchColor)
                                .overlay {
                                    if color.usesLightInk { Circle().strokeBorder(.white.opacity(0.55)) }
                                    if selected { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(color == .black ? .white : .black) }
                                }
                                .frame(width: swatchSize, height: swatchSize)
                            #endif
                            Text(color.title).font(.subheadline.weight(.medium))
                                .foregroundStyle(archive.theme.text)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: swatchSize + 20, alignment: .leading)
                        .background(archive.theme.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? swatchColor : archive.theme.line,
                                                                           lineWidth: selected ? 2 : 1)
                        }
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    .focused($focusedAccent, equals: color)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(prefix + "accent." + color.rawValue)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Glass opacity").font(.headline)
                    Spacer()
                    Text("\(archive.glassOpacity.percent)%").monospacedDigit()
                }
                .accessibilityHidden(true)
                #if os(tvOS)
                GeometryReader { geometry in
                    let progress = Double(archive.glassOpacity.percent) / 100
                    ZStack(alignment: .leading) {
                        Capsule().fill(archive.theme.line).frame(height: 8)
                        Capsule().fill(archive.resolvedAccent)
                            .frame(width: geometry.size.width * progress, height: 8)
                        Circle().fill(archive.resolvedAccent)
                            .overlay { Circle().strokeBorder(.white, lineWidth: focusedSlider ? 4 : 1) }
                            .frame(width: 28, height: 28)
                            .offset(x: (geometry.size.width - 28) * progress)
                    }.frame(maxHeight: .infinity)
                }
                .frame(height: 40)
                .padding(.horizontal, 14)
                .background(archive.theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(focusedSlider ? .white : archive.theme.line,
                                                                   lineWidth: focusedSlider ? 3 : 1)
                }
                .focusable()
                .focused($focusedSlider)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: adjust(by: -5)
                    case .right: adjust(by: 5)
                    case .up: focusedAccent = archive.glassAccent
                    case .down: moveBelowSlider()
                    @unknown default: break
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Glass opacity")
                .accessibilityValue("\(archive.glassOpacity.percent)%")
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { adjust(by: 5) }
                    if direction == .decrement { adjust(by: -5) }
                }
                .accessibilityIdentifier(prefix + "opacity")
                #else
                Slider(value: Binding(get: { Double(archive.glassOpacity.percent) },
                                      set: { archive.setGlassOpacity(Int($0.rounded())) }), in: 0...100, step: 5)
                    .accessibilityLabel("Glass opacity")
                    .accessibilityValue("\(archive.glassOpacity.percent)%")
                    .accessibilityIdentifier(prefix + "opacity")
                #endif
            }
            .padding(14)
            .archivePanel()
        }
    }

    private var swatchSize: CGFloat {
        #if os(tvOS)
        35
        #else
        23
        #endif
    }

    #if os(tvOS)
    private func adjust(by step: Int) { archive.setGlassOpacity(archive.glassOpacity.percent + step) }
    #endif
}
#endif
