import SwiftUI

/// A full title stays available to VoiceOver while only the visible line moves.
struct ArchiveScrollingTitle: View {
    let title: String
    let active: Bool
    let restingLines: Int?
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(_ title: String, active: Bool = true, restingLines: Int? = 1) {
        self.title = title
        self.active = active
        self.restingLines = restingLines
    }

    var body: some View {
        Group {
            if reduceMotion {
                Text(verbatim: title).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            } else if (active || focused) && scenePhase == .active {
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    ScrollingLine(title: title).id(title)
                }
            } else {
                Text(verbatim: title).lineLimit(restingLines)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
    }
}

private struct ScrollingLine: View {
    let title: String
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var textWidth: CGFloat = 0
    @State private var travel: CGFloat = 0

    var body: some View {
        // The label negotiates one line with its siblings. The moving copy cannot grow the row.
        Text(verbatim: title)
            .lineLimit(1)
            .hidden()
            .overlay {
                GeometryReader { viewport in
                    // Ignore subpixel layout changes that would restart the animation.
                    let distance = (max(0, textWidth - viewport.size.width) * displayScale).rounded(.up) / displayScale
                    Text(verbatim: title)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { line in
                                Color.clear.onChange(of: line.size.width, initial: true) { _, width in
                                    textWidth = width
                                }
                            }
                        }
                        // Rasterize the stationary glyphs before translating the layer.
                        .drawingGroup()
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
                        .offset(x: layoutDirection == .rightToLeft ? travel : -travel)
                        .task(id: distance) { await scroll(distance: distance) }
                }
            }
            .clipped()
            .allowsHitTesting(false)
    }

    @MainActor
    private func scroll(distance: CGFloat) async {
        #if os(tvOS)
        let pointsPerSecond = 52.0
        #else
        let pointsPerSecond = 34.0
        #endif
        let duration = max(0.75, distance / pointsPerSecond)
        let glide = Animation.timingCurve(0.24, 0, 0.76, 1, duration: duration)
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { travel = 0 }
        guard distance > 0.5 else { return }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1.4))
                withAnimation(glide) { travel = distance }
                try await Task.sleep(for: .seconds(duration + 1.8))
                withAnimation(glide) { travel = 0 }
                try await Task.sleep(for: .seconds(duration))
            }
        } catch { /* The title, focus, available width or scene changed. */ }
    }
}
