import SwiftUI

enum GradientMotion: String, CaseIterable, Identifiable {
    case drift, rotate, pulse, still

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum GradientSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast

    var id: Self { self }
    var label: String { rawValue.capitalized }

    var period: Double {
        switch self {
        case .slow: 48
        case .normal: 30
        case .fast: 16
        }
    }
}

private enum GradientColor {
    static let first = "#253E7D"
    static let second = "#167F87"
    static let third = "#732E72"
}

private struct GradientPalette: Codable, Identifiable {
    var id = UUID()
    let name: String
    let first: String
    let second: String
    let third: String

    static let presets = [
        Self(name: "Ocean", first: GradientColor.first, second: GradientColor.second, third: GradientColor.third),
        Self(name: "Sunset", first: "#55264F", second: "#A74447", third: "#E18043"),
        Self(name: "Evergreen", first: "#173743", second: "#287657", third: "#7C8F49"),
        Self(name: "Midnight", first: "#101739", second: "#364488", third: "#5E3F7A")
    ]
}

struct AnimatedGradientBackdrop: View {
    @AppStorage("GlassGradientColor1") private var first = ""
    @AppStorage("GlassGradientColor2") private var second = ""
    @AppStorage("GlassGradientColor3") private var third = ""
    @AppStorage("GlassGradientMotion") private var motion = GradientMotion.drift
    @AppStorage("GlassGradientSpeed") private var speed = GradientSpeed.normal
    @AppStorage("GlassGradientDimming") private var dimming = 0.38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let colors = [
            LiquidGlassColor.color(first.isEmpty ? GradientColor.first : first) ?? .indigo,
            LiquidGlassColor.color(second.isEmpty ? GradientColor.second : second) ?? .teal,
            LiquidGlassColor.color(third.isEmpty ? GradientColor.third : third) ?? .purple
        ]
        let paused = reduceMotion || motion == .still || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
            let phase = paused ? 0 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: speed.period) * 2 * .pi / speed.period
            gradient(colors, phase: phase)
        }
        .overlay(Color.black.opacity(dimming))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func gradient(_ colors: [Color], phase: Double) -> some View {
        let angle = motion == .rotate ? phase + 0.6 : 0.6
        let shift = motion == .drift ? sin(phase) * 0.32 : 0
        let pulse = motion == .pulse ? 0.5 - cos(phase) * 0.22 : 0.5
        return ZStack {
            LinearGradient(colors: colors,
                           startPoint: UnitPoint(x: 0.5 - cos(angle) * 0.7, y: 0.5 - sin(angle) * 0.7),
                           endPoint: UnitPoint(x: 0.5 + cos(angle) * 0.7, y: 0.5 + sin(angle) * 0.7))
            RadialGradient(colors: [colors[1].opacity(pulse), .clear],
                           center: UnitPoint(x: 0.5 + shift, y: 0.52 - shift * 0.65),
                           startRadius: 0, endRadius: 650)
        }
    }
}

struct AnimatedGradientSettings: View {
    @AppStorage("GlassGradientColor1") private var first = ""
    @AppStorage("GlassGradientColor2") private var second = ""
    @AppStorage("GlassGradientColor3") private var third = ""
    @AppStorage("GlassGradientMotion") private var motion = GradientMotion.drift
    @AppStorage("GlassGradientSpeed") private var speed = GradientSpeed.normal
    @AppStorage("GlassGradientDimming") private var dimming = 0.38

    @AppStorage("GlassGradientPalettes") private var paletteData = Data()
    @State private var paletteName = ""

    private var savedPalettes: [GradientPalette] {
        (try? JSONDecoder().decode([GradientPalette].self, from: paletteData)) ?? []
    }

    private func apply(_ palette: GradientPalette) {
        first = palette.first
        second = palette.second
        third = palette.third
    }

    private func save(_ palettes: [GradientPalette]) {
        if let data = try? JSONEncoder().encode(palettes) { paletteData = data }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AnimatedGradientBackdrop()
                .frame(height: 90)
                .clipShape(.rect(cornerRadius: 10))
            Menu("Gradient Palettes") {
                ForEach(GradientPalette.presets) { palette in
                    Button(palette.name) { apply(palette) }
                }
                if !savedPalettes.isEmpty {
                    Divider()
                    ForEach(savedPalettes) { palette in
                        Button(palette.name) { apply(palette) }
                    }
                    Menu("Remove Saved Palette") {
                        ForEach(savedPalettes) { palette in
                            Button(palette.name, role: .destructive) {
                                save(savedPalettes.filter { $0.id != palette.id })
                            }
                        }
                    }
                }
            }
            HStack {
                TextField("Palette name", text: $paletteName)
                Button("Save Palette") {
                    let name = paletteName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let palette = GradientPalette(name: name, first: first.isEmpty ? GradientColor.first : first,
                                                  second: second.isEmpty ? GradientColor.second : second,
                                                  third: third.isEmpty ? GradientColor.third : third)
                    save(savedPalettes.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame } + [palette])
                    paletteName = ""
                }.disabled(paletteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text("Dimming")
                #if os(tvOS)
                Button("Decrease Dimming") { dimming = max(0, dimming - 0.05) }.disabled(dimming <= 0)
                Button("Increase Dimming") { dimming = min(0.8, dimming + 0.05) }.disabled(dimming >= 0.8)
                #else
                Slider(value: $dimming, in: 0...0.8, step: 0.01).accessibilityLabel("Gradient dimming")
                #endif
                Text(dimming, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            GlassColorControl(title: "Gradient Color 1", saved: $first, defaultHex: GradientColor.first)
            GlassColorControl(title: "Gradient Color 2", saved: $second, defaultHex: GradientColor.second)
            GlassColorControl(title: "Gradient Color 3", saved: $third, defaultHex: GradientColor.third)
            Picker("Gradient Motion", selection: $motion) {
                ForEach(GradientMotion.allCases) { Text($0.label).tag($0) }
            }
            if motion != .still {
                Picker("Gradient Speed", selection: $speed) {
                    ForEach(GradientSpeed.allCases) { Text($0.label).tag($0) }
                }
            }
        }
    }
}
