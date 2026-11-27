import Combine

@MainActor
public final class ToolDriveTransport: ObservableObject {
    let catalog = ArchiveStore()
    private weak var player: AudioPlayer?
    private var playbackChanges: AnyCancellable?

    public init() {}

    public func prepareCatalog() async { await catalog.load() }

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

    public var message: String { player?.errorMessage ?? "" }
    public var canToggle: Bool { player?.canToggle == true }
    public var playing: Bool { player?.isPlaying == true }
    public var elapsed: Double { player?.elapsed ?? 0 }
    public var duration: Double { player?.duration ?? 0 }
    public var trackTitles: [String] { player?.tracks.map(\.title) ?? [] }
    public var trackIndex: Int? { player?.index }
    public var canPrevious: Bool { !trackTitles.isEmpty }
    public var canNext: Bool { (player?.index ?? 0) + 1 < (player?.tracks.count ?? 0) }
    public func previous() { player?.previous() }
    public func next() { player?.next() }
    public func toggle() { player?.toggle() }
    public func stop() { player?.stop() }
    public func seek(_ seconds: Double) { player?.seek(to: seconds) }
    public func selectTrack(_ index: Int) { player?.selectTrack(index) }
    public func setPlaybackVolume(_ value: Double) { player?.setPlaybackVolume(value) }
    public var equalizerValues: (Double, Double, Double, Bool) {
        let eq = player?.equalizer ?? .flat
        return (eq.bass, eq.mid, eq.treble, eq.magik)
    }
    public func setEqualizer(bass: Double, mid: Double, treble: Double, magik: Bool) {
        player?.setEqualizer(PlaybackEQSettings(bass: bass, mid: mid, treble: treble, magik: magik))
    }
    public func setVisualizerActive(_ active: Bool) { player?.setVisualizerActive(active) }
    public func visualizerLevels() -> [Double] { player?.visualizerLevels() ?? [] }
}
