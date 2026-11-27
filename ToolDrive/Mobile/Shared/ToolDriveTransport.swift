import Combine

@MainActor
public final class ToolDriveTransport: ObservableObject {
    private weak var player: AudioPlayer?
    private var playbackChanges: AnyCancellable?

    public init() {}

    public var title: String? {
        guard let player, player.isVisible else { return nil }
        return player.currentTrack?.title ?? (player.collection.isEmpty ? "Loading recording…" : player.collection)
    }

    public var context: String {
        guard let player else { return "" }
        return player.errorMessage ?? (player.context.isEmpty ? player.collection : player.context)
    }

    func attach(_ player: AudioPlayer) {
        self.player = player
        playbackChanges = player.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        objectWillChange.send()
    }

    func detach(_ player: AudioPlayer) {
        guard self.player === player else { return }
        playbackChanges = nil
        self.player = nil
        objectWillChange.send()
    }

    public func showNowPlaying() { player?.isExpanded = true }
}
