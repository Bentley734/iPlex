import AppKit
import SwiftUI

enum ArchiveResources {
    static func url(_ name: String, _ extension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: `extension`, subdirectory: "ToolDrive")
    }
}

public struct ToolDriveArchiveView: NSViewRepresentable {
    private let appearance: [String: Any]
    private let pauseOutsidePlayback: () -> Void

    public init(title: String, text: String, accent: String, tint: String?, density: Double,
                hover: Bool, pauseOutsidePlayback: @escaping () -> Void) {
        appearance = ["title": title, "text": text, "accent": accent, "tint": tint ?? "",
                      "density": density, "hover": hover]
        self.pauseOutsidePlayback = pauseOutsidePlayback
    }

    public final class Coordinator {
        fileprivate let controller = AppDelegate()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let controller = context.coordinator.controller
        controller.pauseOutsidePlayback = pauseOutsidePlayback
        controller.setIPlexAppearance(appearance)
        controller.start()
        return controller.content
    }

    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.controller.pauseOutsidePlayback = pauseOutsidePlayback
        context.coordinator.controller.setIPlexAppearance(appearance)
    }

    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.controller.stop()
    }
}
