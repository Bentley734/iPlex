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

struct AnimatedGradientBackdrop: View {
    @AppStorage("GlassGradientColor1") private var first = ""
    @AppStorage("GlassGradientColor2") private var second = ""
    @AppStorage("GlassGradientColor3") private var third = ""
    @AppStorage("GlassGradientMotion") private var motion = GradientMotion.drift
    @AppStorage("GlassGradientSpeed") private var speed = GradientSpeed.normal
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
        .overlay(Color.black.opacity(0.38))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AnimatedGradientBackdrop()
                .frame(height: 90)
                .clipShape(.rect(cornerRadius: 10))
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
