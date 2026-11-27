import SwiftUI

enum PageTransitionStyle: String, CaseIterable, Identifiable {
    static let preferenceKey = "PageTransitionStyle"
    case none, fade, slide, zoom

    var id: Self { self }
    var label: String { rawValue.capitalized }

    var animation: Animation? {
        switch self {
        case .none: nil
        case .fade: .easeOut(duration: 0.22)
        case .slide: .easeOut(duration: 0.28)
        case .zoom: .spring(duration: 0.36, bounce: 0.11)
        }
    }

    var presentation: AnyTransition {
        switch self {
        case .none: .identity
        case .fade: .opacity
        case .slide: .offset(x: 28).combined(with: .opacity)
        case .zoom: .scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity)
        }
    }
}

private struct PageTransition<Route: Equatable>: ViewModifier {
    let route: Route
    @AppStorage(PageTransitionStyle.preferenceKey) private var style = PageTransitionStyle.zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Frame {
        var opacity = 1.0
        var offset: CGFloat = 0
        var scale: CGFloat = 1
    }

    func body(content: Content) -> some View {
        let effect = reduceMotion ? .none : style
        let duration = effect == .none ? 0.001 : effect == .fade ? 0.22 : 0.29
        content.keyframeAnimator(initialValue: Frame(), trigger: effect == .none ? nil : route) { view, frame in
            view.opacity(frame.opacity).scaleEffect(frame.scale).offset(x: frame.offset)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                MoveKeyframe(effect == .none ? 1 : 0.42)
                CubicKeyframe(1, duration: duration)
            }
            KeyframeTrack(\.offset) {
                MoveKeyframe(effect == .slide ? 22 : 0)
                CubicKeyframe(0, duration: duration)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(effect == .zoom ? 0.97 : 1)
                CubicKeyframe(1, duration: duration)
            }
        }
    }
}

#if os(macOS) || os(iOS)
private struct GlassHover: ViewModifier {
    let radius: CGFloat
    let lift: Bool
    @MusicAppearance private var appearance
    @AppStorage(glassHoverPreferenceKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var available
    @State private var hovered = false

    func body(content: Content) -> some View {
        let highlight = hovered && enabled && available
        let lifts = highlight && lift && !reduceMotion
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .overlay {
                if highlight {
                    ZStack {
                        if !reduceTransparency {
                            shape.fill(.linearGradient(
                                colors: [.white.opacity(0.17), appearance.accent.opacity(0.055), .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                        }
                        shape.strokeBorder(.linearGradient(
                            colors: [.white.opacity(0.5), appearance.accent.opacity(0.28), .white.opacity(0.14)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 1)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .scaleEffect(lifts ? 1.018 : 1)
            .offset(y: lifts ? -2 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: highlight)
            .onHover { hovered = $0 }
    }
}

#endif

extension View {
    func pageTransition<Route: Equatable>(on route: Route) -> some View {
        modifier(PageTransition(route: route))
    }

    @ViewBuilder func glassHover(radius: CGFloat = 9, lift: Bool = false, when interactive: Bool = true) -> some View {
        #if os(macOS) || os(iOS)
        if interactive { modifier(GlassHover(radius: radius, lift: lift)) }
        else { self }
        #else
        self
        #endif
    }
}

let glassHoverPreferenceKey = "LiquidGlassHoverEffects"
