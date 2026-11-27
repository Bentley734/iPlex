import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class AudioPlayer: ObservableObject {
    enum Phase: Equatable { case idle, resolving, buffering, playing, paused, finished, failed }
    struct Track: Identifiable {
        let id: Int
        let title: String
        let duration: TimeInterval?
    }

    struct ResumePoint: Codable, Equatable {
        enum Source: Codable, Equatable {
            case archive(show: Int, source: Int)
            case plex(show: Int, source: Int)
            case library(UUID)
        }
        let source: Source
        let title: String
        let context: String
        let trackNumber: Int
        let trackTitle: String
        let seconds: Double
        var completedTracks: Int? = nil
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var tracks = [Track]()
    @Published private(set) var index = 0
    @Published private(set) var collection = ""
    @Published private(set) var context = ""
    @Published private(set) var sourceID: Int?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var equalizer = PlaybackEQSettings.flat
    @Published private(set) var equalizerAvailable: Bool?
    @Published var isExpanded = false

    @Published private(set) var resumePoint: ResumePoint?

    private let transport = AVQueuePlayer()
    private var startupRetry: Task<Void, Never>?
    private var startupRetries = 0
    private let defaults: UserDefaults
    private var recordingSource: ResumePoint.Source?
    private var recordingShowID: Int?
    private var completedTracks = 0
    var onShowCompleted: ((Int) -> Void)?
    private var lastCheckpoint: TimeInterval = 0
    private var restoringPosition = false
    private var activeItem: AVPlayerItem?
    private var itemChangeObservation: NSKeyValueObservation?
    private var upcoming: (item: AVPlayerItem, tap: AudioAnalysis, index: Int, hasMix: Bool)?
    private var preparingNext: Task<Void, Never>?
    private let media = LiveMediaService()
    private var audio = [LiveTrack]()
    private var plexLookup: Task<Void, Never>?
    private var retryLive: (() -> Void)?
    private var requestID = UUID()
    private var wantsPlayback = false
    private var resumeAfterInterruption = false
    private var wantsLevels = false
    private var analysis: AudioAnalysis?
    private var analysisPlayingSince: TimeInterval?
    private var preparingAudioMix: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var itemObservers = [NSObjectProtocol]()
    private var sessionObservers = [NSObjectProtocol]()
    private var commands = [(MPRemoteCommand, Any)]()

    var isVisible: Bool { phase != .idle }
    var currentTrack: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    var isPlaying: Bool { phase == .playing || (phase == .buffering && wantsPlayback) }
    var canToggle: Bool { !tracks.isEmpty || phase == .failed }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "resumeRecording"),
           let saved = try? JSONDecoder().decode(ResumePoint.self, from: data),
           saved.seconds.isFinite, saved.seconds >= 0 {
            resumePoint = saved
        }
        itemChangeObservation = transport.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.adoptQueuedItem() }
        }
        transportObservation = transport.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackStatus() }
        }
        timeObserver = transport.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                         queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateTime() }
        }
        let session = AVAudioSession.sharedInstance()
        let notifications = NotificationCenter.default
        sessionObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: session, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(rawType, options: options) }
        })
        sessionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        })
        installRemoteCommands()
    }

    deinit {
        preparingNext?.cancel()
        preparingAudioMix?.cancel()
        if let timeObserver { transport.removeTimeObserver(timeObserver) }
        (itemObservers + sessionObservers).forEach(NotificationCenter.default.removeObserver)
        for (command, target) in commands { command.removeTarget(target) }
        media.cancelAll()
        plexLookup?.cancel()
    }

    func isStreaming(_ source: RecordingSource, fromPlex: Bool) -> Bool {
        isVisible && sourceID == source.id && context.hasPrefix("Plex · ") == fromPlex
    }

    func stream(show: Concert, source: RecordingSource, from plex: MobilePlex? = nil, atTrack number: Int? = nil) {
        guard let version = source.streamVersion else { return }
        if isStreaming(source, fromPlex: plex != nil) && phase != .failed && number == nil {
            isExpanded = true
            return
        }
        resolve(show: show, source: source, version: version, plex: plex, trackNumber: number)
    }

    func resumeLastShow(archive: ArchiveStore, library: MobileLibrary, plex: MobilePlex) async {
        guard let point = resumePoint else { return }
        switch point.source {
        case let .archive(showID, sourceID), let .plex(showID, sourceID):
            guard let show = archive.shows.first(where: { $0.id == showID }),
                  let source = show.sources.first(where: { $0.id == sourceID }),
                  let version = source.streamVersion else {
                fail("This recording is no longer in the catalog.")
                isExpanded = true
                return
            }
            let server: MobilePlex?
            if case .plex = point.source { server = plex } else { server = nil }
            resolve(show: show, source: source, version: version, plex: server, resumePoint: point)
        case .library(let id):
            await library.load()
            guard resumePoint == point else { return }
            guard let record = library.records.first(where: { $0.id == id }) else {
                fail("This recording is no longer in the Library.")
                isExpanded = true
                return
            }
            play(tracks: library.playable(record), title: record.title, context: record.context,
                 expandPlayer: true, libraryID: id, archiveShowID: record.archiveShowID, resumePoint: point)
        }
    }

    private func cancelResolution() {
        requestID = UUID()
        media.cancelTrackResolution()
        plexLookup?.cancel()
        plexLookup = nil
    }

    private func resolve(show: Concert, source: RecordingSource, version: Int, plex: MobilePlex?,
                         resumePoint: ResumePoint? = nil, trackNumber: Int? = nil) {
        saveProgress(force: true)
        cancelResolution()
        clearItem()
        recordingShowID = show.id
        recordingSource = plex == nil ? .archive(show: show.id, source: source.id) : .plex(show: show.id, source: source.id)
        equalizer = .flat
        audio = []
        tracks = []
        index = 0
        sourceID = source.id
        collection = show.venue.isEmpty ? show.date : show.venue
        context = plex == nil ? [show.date, show.location, source.version].filter { !$0.isEmpty }.joined(separator: " · ")
                              : "Plex · " + show.date
        errorMessage = nil
        phase = .resolving
        wantsPlayback = true
        updateNowPlaying()
        retryLive = { [weak self] in
            self?.resolve(show: show, source: source, version: version, plex: plex,
                          resumePoint: resumePoint, trackNumber: trackNumber)
        }
        let request = requestID
        if let plex {
            plexLookup = Task { [weak self] in
                do {
                    let match = try await plex.recording(show: show, source: source, version: version)
                    guard let self, self.requestID == request else { return }
                    let tracks = try match.validatedPlaybackTracks()
                    self.collection = match.collection
                    self.install(tracks, startIndex: 0, autoplay: self.wantsPlayback, resumePoint: resumePoint)
                } catch {
                    guard let self, self.requestID == request else { return }
                    self.fail(error.localizedDescription)
                }
                if self?.requestID == request { self?.plexLookup = nil }
            }
            return
        }
        media.resolveTracks(showID: show.id, sourceID: source.id, date: show.date, version: version) { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestID == request else { return }
                switch result {
                case .success(let found):
                    let index = trackNumber.flatMap { number in found.firstIndex { $0.number == number } }
                    guard trackNumber == nil || index != nil else {
                        self.fail("This track is no longer available in the recording.")
                        return
                    }
                    self.install(found, startIndex: index ?? 0, autoplay: self.wantsPlayback, resumePoint: resumePoint)
                case .failure:
                    self.fail("The archive couldn’t provide this recording. Check your connection and try again.")
                }
            }
        }
    }

    func play(tracks: [LiveTrack], title: String, context: String, startIndex: Int = 0, expandPlayer: Bool = false,
              libraryID: UUID? = nil, archiveShowID: Int? = nil, resumePoint: ResumePoint? = nil) {
        guard !tracks.isEmpty else {
            if resumePoint != nil { fail("The saved recording’s audio files are unavailable."); isExpanded = true }
            return
        }
        saveProgress(force: true)
        cancelResolution()
        clearItem()
        retryLive = nil
        recordingShowID = archiveShowID
        recordingSource = libraryID.map { .library($0) }
        sourceID = nil
        equalizer = .flat
        collection = title
        self.context = context
        if expandPlayer { isExpanded = true }
        install(tracks, startIndex: startIndex, resumePoint: resumePoint)
    }

    private func install(_ found: [LiveTrack], startIndex: Int, autoplay: Bool = true, resumePoint: ResumePoint? = nil) {
        completedTracks = 0
        guard !found.isEmpty else { fail("The recording contains no playable tracks."); return }
        audio = found
        tracks = found.enumerated().map { index, track in
            let length = track.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Track(id: index, title: track.title, duration: length)
        }
        retryLive = nil
        if let resumePoint {
            guard let restored = found.firstIndex(where: { $0.number == resumePoint.trackNumber && $0.title == resumePoint.trackTitle }) else {
                fail("The saved track has changed. Open the recording to choose a track.")
                return
            }
            completedTracks = min(restored, max(0, resumePoint.completedTracks ?? 0))
            selectTrack(restored, autoplay: autoplay, startAt: resumePoint.seconds)
        } else {
            selectTrack(min(max(0, startIndex), found.count - 1), autoplay: autoplay)
        }
    }

    func setPlaybackVolume(_ value: Double) {
        if value.isFinite { transport.volume = Float(min(1, max(0, value))) }
    }

    func selectTrack(_ requested: Int, autoplay: Bool = true, startAt: Double = 0) {
        startupRetries = 0
        openTrack(requested, autoplay: autoplay, startAt: startAt)
    }

    private func openTrack(_ requested: Int, autoplay: Bool, startAt: Double) {
        guard audio.indices.contains(requested) else { return }
        clearItem()
        index = requested
        errorMessage = nil
        duration = tracks[requested].duration ?? 0
        wantsPlayback = autoplay
        phase = autoplay ? .buffering : .paused
        let item = AVPlayerItem(url: audio[requested].url)
        activeItem = item
        transport.insert(item, after: nil)
        configureProcessing(startAt: startAt)
        observeActiveItem(item)
        if autoplay { resume() } else { updateNowPlaying() }
        if autoplay { schedulePlexRetry(for: item, startAt: startAt) }
    }

    private func schedulePlexRetry(for item: AVPlayerItem, startAt: Double = 0, interrupted: Bool = false) {
        guard case .plex? = recordingSource, wantsPlayback, startupRetry == nil else { return }
        startupRetry = Task { [weak self, weak item] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, let item, self.activeItem === item else { return }
            self.startupRetry = nil
            guard self.wantsPlayback, interrupted || self.transport.timeControlStatus != .playing || item.status == .failed else { return }
            guard self.startupRetries < 2 else {
                self.fail("Plex audio is unavailable. Press Play to retry this track.")
                return
            }
            self.startupRetries += 1
            self.openTrack(self.index, autoplay: true, startAt: max(startAt, self.elapsed))
            if self.phase != .playing { self.errorMessage = "Retrying Plex audio…" }
        }
    }

    private func observeActiveItem(_ item: AVPlayerItem) {
        itemObservation?.invalidate()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.transport.currentItem === item else { return }
                if item.status == .failed {
                    if case .plex? = self.recordingSource, self.wantsPlayback {
                        self.schedulePlexRetry(for: item)
                    } else {
                        self.fail("This track couldn’t be played. Retry it or choose another track.")
                    }
                }
                else if item.status == .readyToPlay { self.updateTime(); self.updatePlaybackStatus() }
            }
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.activeItem === item else { return }
                if self.upcoming != nil {
                    self.adoptQueuedItem()
                    return
                }
                if self.completedTracks == self.index { self.completedTracks += 1 }
                if self.index + 1 < self.audio.count { self.selectTrack(self.index + 1, autoplay: self.wantsPlayback) }
                else {
                    self.clearCompletedProgress()
                    self.wantsPlayback = false
                    self.phase = .finished
                    if self.completedTracks == self.audio.count, let id = self.recordingShowID {
                        self.onShowCompleted?(id)
                    }
                    self.updateTime()
                    self.updateNowPlaying()
                    self.deactivateSession()
                }
            }
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.transport.currentItem === item else { return }
                if case .plex? = self.recordingSource, self.wantsPlayback {
                    self.errorMessage = "Retrying Plex audio…"
                    self.schedulePlexRetry(for: item, interrupted: true)
                } else {
                    self.fail("Playback stopped before the end of this track.")
                }
            }
        })
    }

    func toggle() {
        if isPlaying { pause() }
        else if phase == .failed {
            if tracks.indices.contains(index) { selectTrack(index, startAt: elapsed) }
            else { retryLive?() }
        }
        else if phase == .finished { completedTracks = 0; selectTrack(0) }
        else { resume() }
    }

    private func resume() {
        guard transport.currentItem != nil else { return }
        if preparingAudioMix != nil {
            wantsPlayback = true
            phase = .buffering
            updateNowPlaying()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch { fail("The audio output is unavailable. Check the selected output and try again."); return }
        wantsPlayback = true
        resumeAfterInterruption = false
        phase = .buffering
        transport.play()
        updatePlaybackStatus()
    }

    func pause() {
        startupRetry?.cancel()
        startupRetry = nil
        saveProgress(force: true)
        resumeAfterInterruption = false
        wantsPlayback = false
        guard !tracks.isEmpty else { return }
        transport.pause()
        if phase != .failed && phase != .finished { phase = .paused }
        updateNowPlaying()
    }

    func previous() {
        if elapsed > 3 || index == 0 { seek(to: 0) }
        else { selectTrack(index - 1, autoplay: wantsPlayback) }
    }

    func next() { if index + 1 < tracks.count { selectTrack(index + 1, autoplay: wantsPlayback) } }

    func seek(to value: Double) {
        guard value.isFinite, duration > 0, let item = transport.currentItem else { return }
        let target = max(0, min(value, duration))
        transport.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            Task { @MainActor in
                guard finished, let self, let item, self.transport.currentItem === item else { return }
                self.saveProgress(force: true)
            }
        }
        elapsed = target
        if phase == .finished { phase = .paused }
        updateNowPlaying()
    }

    func stop() {
        saveProgress(force: true)
        cancelResolution()
        clearItem()
        recordingSource = nil
        recordingShowID = nil
        equalizer = .flat
        wantsLevels = false
        wantsPlayback = false
        sourceID = nil
        retryLive = nil
        errorMessage = nil
        tracks = []
        audio = []
        isExpanded = false
        phase = .idle
        updateNowPlaying()
        deactivateSession()
    }

    private func clearItem() {
        startupRetry?.cancel()
        startupRetry = nil
        resumeAfterInterruption = false
        transport.pause()
        preparingNext?.cancel()
        preparingNext = nil
        upcoming = nil
        activeItem = nil
        restoringPosition = false
        detachProcessing()
        itemObservation?.invalidate()
        itemObservation = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        transport.removeAllItems()
        elapsed = 0
        duration = 0
    }

    private func deactivateSession() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

    private func updateTime() {
        adoptQueuedItem()
        guard let item = transport.currentItem else { return }
        let time = item.currentTime().seconds
        if time.isFinite { elapsed = max(0, time) }
        let length = item.duration.seconds
        if length.isFinite && length > 0 { duration = length }
        if let analysis {
            if let available = analysis.equalizerAvailable {
                if equalizerAvailable != available { equalizerAvailable = available }
                analysisPlayingSince = nil
            } else if transport.timeControlStatus == .playing {
                let now = ProcessInfo.processInfo.systemUptime
                if let start = analysisPlayingSince {
                    if now - start > 2 && equalizerAvailable != false { equalizerAvailable = false }
                } else { analysisPlayingSince = now }
            } else { analysisPlayingSince = nil }
        }
        saveProgress()
    }

    func setVisualizerActive(_ active: Bool) {
        guard wantsLevels != active else { return }
        wantsLevels = active
        analysis?.configure(settings: equalizer, levels: active)
        upcoming?.tap.configure(settings: equalizer, levels: active)
    }

    func visualizerLevels() -> [Double] {
        guard wantsLevels, phase == .playing, let analysis else { return [0, 0, 0] }
        return analysis.levels(at: transport.currentTime().seconds)
    }

    var visualizerPosition: TimeInterval {
        let time = transport.currentTime().seconds
        return time.isFinite ? max(0, time) : elapsed
    }

    func setEqualizer(_ settings: PlaybackEQSettings) {
        guard settings != equalizer else { return }
        equalizer = settings
        configureProcessing()
        upcoming?.tap.configure(settings: settings, levels: wantsLevels)
    }

    private func configureProcessing(startAt: Double = 0) {
        guard let item = transport.currentItem else { return }
        if let analysis { analysis.configure(settings: equalizer, levels: wantsLevels); return }
        let tap = AudioAnalysis()
        analysis = tap
        restoringPosition = startAt > 0
        tap.configure(settings: equalizer, levels: wantsLevels)
        let preparation = Task { [weak self, weak item, weak tap] in
            guard let item, let tap else { return }
            let tracks = try? await item.asset.archiveAudioTracks()
            guard !Task.isCancelled, let self, self.transport.currentItem === item, self.analysis === tap else { return }
            if let track = tracks?.first, let mix = tap.mix(for: track) {
                item.audioMix = mix
            } else {
                self.equalizerAvailable = false
            }
            if startAt > 0 {
                let measured = try? await item.asset.archiveDuration().seconds
                guard !Task.isCancelled, self.activeItem === item else { return }
                let limit = measured.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? self.tracks[self.index].duration
                let target = min(startAt, limit.map { max(0, $0 - 0.25) } ?? startAt)
                await withCheckedContinuation { continuation in
                    self.transport.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled, self.activeItem === item else { return }
                self.restoringPosition = false
                self.updateTime()
            }
            self.preparingAudioMix = nil
            self.prepareNext(after: item)
            if self.wantsPlayback && self.phase != .failed { self.resume() }
        }
        // Install a single tap before the track starts. Opening the visualizer
        // only enables spectrum analysis on the existing tap.
        preparingAudioMix = preparation
    }

    private func prepareNext(after item: AVPlayerItem) {
        let following = index + 1
        guard audio.indices.contains(following) else { return }
        let next = AVPlayerItem(url: audio[following].url)
        let tap = AudioAnalysis()
        preparingNext = Task { [weak self, weak item] in
            let assetTracks = try? await next.asset.archiveAudioTracks()
            guard !Task.isCancelled, let self, let item, self.activeItem === item,
                  self.transport.currentItem === item, self.transport.canInsert(next, after: item) else { return }
            if let track = assetTracks?.first { next.audioMix = tap.mix(for: track) }
            tap.configure(settings: self.equalizer, levels: self.wantsLevels)
            self.upcoming = (next, tap, following, next.audioMix != nil)
            self.preparingNext = nil
            self.transport.insert(next, after: item)
        }
    }

    private func adoptQueuedItem() {
        guard let next = upcoming, transport.currentItem === next.item else { return }
        upcoming = nil
        activeItem = next.item
        if completedTracks == index { completedTracks += 1 }
        index = next.index
        elapsed = 0
        duration = tracks[index].duration ?? 0
        analysis = next.tap
        analysisPlayingSince = nil
        equalizerAvailable = next.hasMix ? nil : false
        observeActiveItem(next.item)
        prepareNext(after: next.item)
        saveProgress(force: true)
        updateNowPlaying()
    }

    func saveProgress(force: Bool = false) {
        guard !restoringPosition, let source = recordingSource, audio.indices.contains(index),
              let item = transport.currentItem, item === activeItem, item.status == .readyToPlay,
              phase != .finished && phase != .failed else { return }
        let seconds = item.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        if seconds < 1, index == 0, resumePoint?.source != source { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheckpoint >= 5 else { return }
        let track = audio[index]
        let point = ResumePoint(source: source, title: collection, context: context,
                                trackNumber: track.number, trackTitle: track.title, seconds: seconds, completedTracks: completedTracks)
        lastCheckpoint = now
        guard point != resumePoint else { return }
        guard let data = try? JSONEncoder().encode(point) else { return }
        defaults.set(data, forKey: "resumeRecording")
        resumePoint = point
    }

    private func clearCompletedProgress() {
        guard let recordingSource, resumePoint?.source == recordingSource else { return }
        clearResumePoint()
    }

    func clearResumePoint() {
        defaults.removeObject(forKey: "resumeRecording")
        resumePoint = nil
    }

    private func detachProcessing() {
        preparingAudioMix?.cancel()
        preparingAudioMix = nil
        guard analysis != nil else { return }
        analysis = nil
        transport.currentItem?.audioMix = nil
        analysisPlayingSince = nil
        equalizerAvailable = nil
    }

    private func updatePlaybackStatus() {
        guard transport.currentItem != nil, phase != .failed, phase != .finished else { return }
        let next: Phase = !wantsPlayback ? .paused : (transport.timeControlStatus == .playing ? .playing : .buffering)
        if next == .playing {
            startupRetry?.cancel()
            startupRetry = nil
            if startupRetries > 0 { errorMessage = nil }
        } else if next == .buffering, let item = activeItem {
            schedulePlexRetry(for: item)
        }
        if phase != next { phase = next }
        updateNowPlaying()
    }

    private func fail(_ message: String) {
        wantsPlayback = false
        transport.pause()
        phase = .failed
        errorMessage = message
        updateNowPlaying()
        deactivateSession()
    }

    private func handleInterruption(_ raw: UInt?, options: UInt) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let shouldResume = isPlaying
            pause()
            resumeAfterInterruption = shouldResume
        } else if type == .ended, resumeAfterInterruption {
            resumeAfterInterruption = false
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { resume() }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer) -> Void) {
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
            commands.append((command, token))
        }
        bind(center.playCommand) { if !$0.isPlaying { $0.toggle() } }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }
        bind(center.nextTrackCommand) { $0.next() }
        bind(center.previousTrackCommand) { $0.previous() }
        let seekCommand = center.changePlaybackPositionCommand
        commands.append((seekCommand, seekCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = canToggle && !isPlaying
        center.pauseCommand.isEnabled = isPlaying
        center.togglePlayPauseCommand.isEnabled = canToggle
        center.nextTrackCommand.isEnabled = index + 1 < tracks.count
        center.previousTrackCommand.isEnabled = currentTrack != nil
        center.changePlaybackPositionCommand.isEnabled = duration > 0
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyAlbumTitle: collection,
                                   MPMediaItemPropertyArtist: "TOOL", MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                                   MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
                                   MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
                                   MPNowPlayingInfoPropertyPlaybackQueueCount: tracks.count]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension RecordingSource {
    var recordingVersion: Int? {
        guard version.range(of: "^V\\.[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        return Int(version.dropFirst(2))
    }

    var streamVersion: Int? {
        status == "OTD" ? recordingVersion : nil
    }
}

extension AVAsset {
    func archiveAudioTracks() async throws -> [AVAssetTrack] {
        if #available(iOS 15, tvOS 15, *) { return try await loadTracks(withMediaType: .audio) }
        try await loadLegacyProperty("tracks")
        return tracks(withMediaType: .audio)
    }

    func archiveDuration() async throws -> CMTime {
        if #available(iOS 15, tvOS 15, *) { return try await load(.duration) }
        try await loadLegacyProperty("duration")
        return duration
    }

    func archivePlayable() async throws -> Bool {
        if #available(iOS 15, tvOS 15, *) { return try await load(.isPlayable) }
        try await loadLegacyProperty("playable")
        return isPlayable
    }

    private func loadLegacyProperty(_ key: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadValuesAsynchronously(forKeys: [key]) {
                var error: NSError?
                if self.statusOfValue(forKey: key, error: &error) == .loaded {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? URLError(.cannotDecodeRawData))
                }
            }
        }
    }
}
