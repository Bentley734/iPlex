import AppKit
import SwiftUI

enum ArchiveResources {
    static func url(_ name: String, _ extension: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: `extension`, subdirectory: "ToolDrive")
    }
}

@MainActor
public final class ToolDriveTransport: ObservableObject {
    @Published public private(set) var catalogReady = false
    @Published public private(set) var catalogFailed = false
    @Published public private(set) var title: String?
    @Published public private(set) var context = ""
    @Published public private(set) var message = ""
    @Published public private(set) var playing = false
    @Published public private(set) var canToggle = false
    @Published public private(set) var canPrevious = false
    @Published public private(set) var canNext = false
    @Published public private(set) var elapsed = 0.0
    @Published public private(set) var duration = 0.0
    @Published public private(set) var trackTitles: [String] = []
    @Published public private(set) var trackIndex: Int?
    var equalizer = PlaybackEQSettings.flat
    var levels: [Double] = []
    fileprivate weak var controller: AppDelegate?

    public init() {}

    func update(_ state: [String: Any]) {
        let visible = state["visible"] as? Bool == true
        let status = state["status"] as? String
        let tracks = state["tracks"] as? [[String: Any]] ?? []
        let ready = visible && !tracks.isEmpty && status != "loading" && status != "resolving"
        let newTitle = visible ? state["title"] as? String : nil
        let newContext = state["context"] as? String ?? ""
        let newMessage = state["message"] as? String ?? ""
        let newElapsed = state["elapsed"] as? Double ?? 0
        let newDuration = ready ? state["duration"] as? Double ?? 0 : 0
        let previous = ready && state["canPrevious"] as? Bool == true
        let next = ready && state["canNext"] as? Bool == true
        if title != newTitle { title = newTitle }
        if context != newContext { context = newContext }
        if message != newMessage { message = newMessage }
        if playing != (status == "playing") { playing = status == "playing" }
        if canToggle != ready { canToggle = ready }
        if canPrevious != previous { canPrevious = previous }
        if canNext != next { canNext = next }
        if elapsed != newElapsed { elapsed = newElapsed }
        if duration != newDuration { duration = newDuration }
        let titles = tracks.map { $0["title"] as? String ?? "Track" }
        if trackTitles != titles { trackTitles = titles }
        let index = state["trackIndex"] as? Int
        if trackIndex != index { trackIndex = index }
    }

    func updateCatalog(ready: Bool, failed: Bool = false) {
        if catalogReady != ready { catalogReady = ready }
        if catalogFailed != failed { catalogFailed = failed }
    }

    public func reloadCatalog() { controller?.loadCatalogPage() }
    public func refreshPlex() { controller?.handlePlex(["action": "status"]) }
    public func toggle() { controller?.handlePlayer(["action": "toggle"]) }
    public func previous() { controller?.handlePlayer(["action": "previous"]) }
    public func next() { controller?.handlePlayer(["action": "next"]) }
    public func seek(_ seconds: Double) { controller?.handlePlayer(["action": "seek", "seconds": seconds]) }
    public func stop() { controller?.handlePlayer(["action": "close"]) }
    public func selectTrack(_ index: Int) { controller?.handlePlayer(["action": "playTrack", "index": index]) }
    public var equalizerValues: (Double, Double, Double, Bool) {
        (equalizer.bass, equalizer.mid, equalizer.treble, equalizer.magik)
    }
    public func setEqualizer(bass: Double, mid: Double, treble: Double, magik: Bool) {
        equalizer = PlaybackEQSettings(bass: bass, mid: mid, treble: treble, magik: magik)
        controller?.setPlaybackEqualizer(equalizer)
    }
    public func setVisualizerActive(_ active: Bool) { controller?.setPlaybackVisualizer(active) }
    public func visualizerLevels() -> [Double] { levels }

}

public struct ToolDriveArchiveView: NSViewRepresentable {
    private let appearance: [String: Any]
    private let active: Bool
    private let transport: ToolDriveTransport
    private let volume: Double
    private let pauseOutsidePlayback: () -> Void
    private let openPlexSettings: () -> Void

    public init(title: String, active: Bool, text: String, accent: String, tint: String?, density: Double,
                hover: Bool, transport: ToolDriveTransport, volume: Double, pauseOutsidePlayback: @escaping () -> Void,
                openPlexSettings: @escaping () -> Void) {
        self.transport = transport
        self.active = active
        self.volume = volume
        appearance = ["title": title, "text": text, "accent": accent, "tint": tint ?? "",
                      "density": density, "hover": hover]
        self.pauseOutsidePlayback = pauseOutsidePlayback
        self.openPlexSettings = openPlexSettings
    }

    public final class Coordinator {
        fileprivate let controller = AppDelegate()
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let controller = context.coordinator.controller
        transport.controller = controller
        controller.transport = transport
        controller.content.isHidden = !active
        controller.setPlaybackVolume(volume)
        controller.pauseOutsidePlayback = pauseOutsidePlayback
        controller.openPlexSettings = openPlexSettings
        controller.setIPlexAppearance(appearance)
        controller.setCatalogActive(active)
        DispatchQueue.main.async { [weak controller] in
            if controller?.transport != nil { controller?.start() }
        }
        return controller.content
    }

    public func updateNSView(_ view: NSView, context: Context) {
        view.isHidden = !active
        context.coordinator.controller.pauseOutsidePlayback = pauseOutsidePlayback
        context.coordinator.controller.openPlexSettings = openPlexSettings
        context.coordinator.controller.setIPlexAppearance(appearance)
        context.coordinator.controller.setPlaybackVolume(volume)
        context.coordinator.controller.setCatalogActive(active)
    }

    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        let controller = coordinator.controller
        let transport = controller.transport
        controller.transport = nil
        controller.stop()
        Task { @MainActor in
            if transport?.controller === controller {
                transport?.controller = nil
                transport?.updateCatalog(ready: false)
                transport?.update([:])
            }
        }
    }
}
