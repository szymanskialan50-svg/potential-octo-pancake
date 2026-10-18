import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer

final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

enum RepeatMode: Int { case off, all, one }

enum NowPlayingArtwork {
    // Built outside any actor: MediaPlayer calls this block on a background queue.
    static func make(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var artwork: UIImage? = nil
    @Published private(set) var palette: [UIColor] = []
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off

    let clock = PlaybackClock()
    let lyrics = LyricsController()

    private let settings: AppSettings
    private let toast: ToastCenter

    /// Natywny odtwarzacz: dźwięk idzie bezpośrednio przez AVPlayer, więc iOS traktuje aplikację jak
    /// zwykły odtwarzacz muzyki - gra w tle i przy zablokowanym ekranie bez żadnych obejść.
    private let player = AVPlayer()
    private var itemObservers: [NSKeyValueObservation] = []
    private var playerObservers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// What the user wants (play / pause). The button always follows this, never the delayed player state,
    /// so tapping fast cannot leave the button and the sound out of sync.
    @Published private(set) var wantsPlaying = false
    private var ended = false
    private var interrupted = false
    private var wasPlayingBeforeInterruption = false
    private var failures = 0
    private var lastTime = 0.0
    private var isSeeking = false
    private var history: [Int] = []
    private var shuffleBag: [Int] = []
    private var plannedNext: Int? = nil
    private var observers: [NSObjectProtocol] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var lastNowPlayingDuration = 0.0
    private var nowPlayingTick = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var watchdog: Task<Void, Never>?
    private var stalledTicks = 0
    private var reloadAttempts = 0
    private var lastToggle = Date.distantPast
    private var refreshedURLForCurrent = false
    /// True while the stream address is being fetched (the player has no item yet).
    private var resolving = false
    private var resolveTicks = 0
    private var playingLocalFile = false

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    init(settings: AppSettings, toast: ToastCenter) {
        self.settings = settings
        self.toast = toast
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        activateSession()
        setupPlayerObservers()
        setupRemoteCommands()
        observeSystem()
        updateLatency()
        startWatchdog()
    }

    // MARK: - Public controls

    func play(_ tracks: [Track], startAt index: Int, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        history = []
        plannedNext = nil
        if shuffled { shuffle = true }
        let start = shuffled ? Int.random(in: 0..<tracks.count) : min(max(index, 0), tracks.count - 1)
        shuffleBag = shuffle ? Array(tracks.indices) : []
        failures = 0
        load(index: start, pushHistory: false)
    }

    func playNow(_ track: Track) { play([track], startAt: 0) }

    func enqueueNext(_ track: Track) {
        guard let cur = currentIndex else { playNow(track); return }
        queue.insert(track, at: cur + 1)
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != cur } : []
        plannedNext = nil
        prefetchNext()
        toast.show("Zagra jako następna")
    }

    func enqueueLast(_ track: Track) {
        guard currentIndex != nil else { playNow(track); return }
        queue.append(track)
        if shuffle { shuffleBag.append(queue.count - 1) }
        plannedNext = nil
        prefetchNext()
        toast.show("Dodano do kolejki")
    }

    func jump(to index: Int) { load(index: index, pushHistory: true) }

    func removeFromQueue(at offsets: IndexSet) {
        guard let cur = currentIndex else { return }
        let removable = offsets.filter { $0 != cur }
        let shift = removable.filter { $0 < cur }.count
        queue.remove(atOffsets: IndexSet(removable))
        currentIndex = cur - shift
        history = []
        plannedNext = nil
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != currentIndex } : []
        prefetchNext()
    }

    func play() {
        guard let t = currentTrack else { return }
        wantsPlaying = true
        interrupted = false
        stalledTicks = 0
        reloadAttempts = 0
        activateSession()
        if ended {
            ended = false
            clock.time = 0
            lastTime = 0
            startLoad(track: t, startAt: 0)
        } else if player.currentItem == nil {
            if !resolving { startLoad(track: t, startAt: lastTime) }
        } else {
            player.play()
        }
        updateNowPlaying()
    }

    func pause() {
        wantsPlaying = false
        player.pause()
        isPlaying = false
        isBuffering = false
        updateNowPlaying()
    }

    func togglePlayPause() {
        // Ignore the accidental extra tap of a fast double-tap.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = now
        if wantsPlaying { pause() } else { play() }
    }

    func next() {
        if let n = nextIndex(auto: false) { load(index: n, pushHistory: true) }
    }

    func previous() {
        if clock.time > 3 || currentIndex == nil { seek(to: 0); return }
        if shuffle, let last = history.popLast() { load(index: last, pushHistory: false); return }
        if !shuffle, let cur = currentIndex, cur > 0 { load(index: cur - 1, pushHistory: false); return }
        seek(to: 0)
    }

    func seek(to seconds: Double) {
        let upper = clock.duration > 0 ? clock.duration : max(seconds, 0)
        let t = max(0, min(seconds, upper))
        clock.time = t
        lastTime = t
        lyrics.tick(t)
        guard player.currentItem != nil else { updateNowPlaying(); return }
        isSeeking = true
        let target = CMTime(seconds: t, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                self.updateNowPlaying()
            }
        }
        updateNowPlaying()
    }

    func skip(by delta: Double) { seek(to: clock.time + delta) }

    func toggleShuffle() {
        shuffle.toggle()
        history = []
        plannedNext = nil
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != currentIndex } : []
        prefetchNext()
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
        plannedNext = nil
        prefetchNext()
    }

    func adjustLyricsOffset(by delta: Double) {
        guard let t = currentTrack else { return }
        let value = (lyrics.offset + delta * 1000).rounded() / 1000
        lyrics.setOffset(value)
        settings.setLyricsOffset(value, for: t.id)
    }

    func resetLyricsOffset() {
        guard let t = currentTrack else { return }
        lyrics.setOffset(0)
        lyrics.setStretch(1)
        settings.setLyricsOffset(0, for: t.id)
        settings.setLyricsStretch(1, for: t.id)
    }

    /// Tempo tekstu: dodatnie `percent` = tekst wolniejszy, ujemne = szybszy (zapamiętywane dla piosenki).
    func adjustLyricsTempo(byPercent percent: Double) {
        guard let t = currentTrack else { return }
        let value = ((lyrics.stretch * (1 + percent / 100)) * 1000).rounded() / 1000
        lyrics.setStretch(value)
        settings.setLyricsStretch(lyrics.stretch, for: t.id)
    }

    func chooseLyrics(_ candidate: LyricsCandidate) {
        guard let t = currentTrack else { return }
        lyrics.choose(candidate, for: t)
    }

    /// Pobiera od nowa adres strumienia bieżącego utworu i wznawia od tego samego miejsca.
    func reloadPlayer() {
        guard let t = currentTrack else { return }
        reloadAttempts = 0
        stalledTicks = 0
        isBuffering = wantsPlaying
        startLoad(track: t, startAt: lastTime, forceRefresh: true)
    }

    // MARK: - Loading

    private func load(index: Int, pushHistory: Bool, startAt: Double = 0) {
        guard queue.indices.contains(index) else { return }
        if pushHistory, let cur = currentIndex {
            history.append(cur)
            if history.count > 200 { history.removeFirst() }
        }
        currentIndex = index
        plannedNext = nil
        shuffleBag.removeAll { $0 == index }
        let track = queue[index]
        wantsPlaying = true
        ended = false
        isBuffering = true
        isPlaying = false
        stalledTicks = 0
        reloadAttempts = 0
        refreshedURLForCurrent = false
        clock.time = startAt
        clock.duration = track.duration
        lastTime = startAt
        artwork = nil
        nowPlayingArtwork = nil
        activateSession()
        beginBackgroundGrace()
        detachItem()
        startLoad(track: track, startAt: startAt)
        lyrics.load(track: track, offset: settings.lyricsOffset(for: track.id), stretch: settings.lyricsStretch(for: track.id))
        loadArtwork(for: track)
        updateNowPlaying()
    }

    /// Gets the stream address (YouTubeKit) and hands it to AVPlayer.
    private func startLoad(track: Track, startAt: Double, forceRefresh: Bool = false) {
        loadTask?.cancel()
        let token = UUID()
        loadToken = token
        resolving = true
        loadTask = Task { [weak self] in
            do {
                // 1) Już pobrany na dysk -> start natychmiast, bez internetu.
                if !forceRefresh, let local = await AudioCache.shared.localURL(for: track.id) {
                    guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                    self.attach(url: local, track: track, startAt: startAt, local: true)
                    return
                }
                // 2) Nie ma go jeszcze: gramy ze strumienia, a w tle pobieramy go na stałe.
                let stream = try await StreamResolver.shared.resolve(track.id, forceRefresh: forceRefresh)
                guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                self.attach(url: stream.url, track: track, startAt: startAt, local: false)
            } catch {
                guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                self.handleResolveFailure(error)
            }
        }
    }

    /// Stops the previous song so its time can never leak into the next one.
    private func detachItem() {
        itemObservers.removeAll()
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isSeeking = false
    }

    private func attach(url: URL, track: Track, startAt: Double, local: Bool) {
        resolving = false
        playingLocalFile = local
        let item = AVPlayerItem(url: url)
        observe(item: item)
        player.replaceCurrentItem(with: item)
        if startAt > 0.5 {
            isSeeking = true
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.isSeeking = false }
            }
        }
        if wantsPlaying && !interrupted { player.play() }
        if !local {
            let id = track.id
            Task.detached(priority: .utility) { await AudioCache.shared.ensure(id) }
        }
        prefetchNext()
    }

    private func loadArtwork(for track: Track) {
        Task { [weak self] in
            let image = await ArtworkLoader.shared.artwork(for: track.id)
            guard let self = self, self.currentTrack?.id == track.id else { return }
            self.artwork = image
            self.palette = image.map { ArtworkLoader.palette(from: $0) } ?? []
            self.nowPlayingArtwork = image.map { NowPlayingArtwork.make($0) }
            self.updateNowPlaying()
        }
    }

    private func nextIndex(auto: Bool) -> Int? {
        if let p = plannedNext, queue.indices.contains(p) { return p }
        guard let cur = currentIndex, !queue.isEmpty else { return nil }
        var result: Int? = nil
        if shuffle && queue.count > 1 {
            if shuffleBag.isEmpty {
                if auto && repeatMode == .off { return nil }
                shuffleBag = Array(queue.indices).filter { $0 != cur }
            }
            result = shuffleBag.randomElement()
        } else if cur + 1 < queue.count {
            result = cur + 1
        } else if repeatMode == .all {
            result = 0
        }
        plannedNext = result
        return result
    }

    /// Resolves the stream of the upcoming song in advance, so switching songs (also in the background) is instant.
    private func prefetchNext() {
        guard repeatMode != .one, let n = nextIndex(auto: true), queue.indices.contains(n) else { return }
        let id = queue[n].id
        Task.detached(priority: .utility) { await AudioCache.shared.ensure(id) }
    }

    // MARK: - Player events

    private func setupPlayerObservers() {
        playerObservers.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncTimeControlStatus() }
        })
        // 10x na sekundę: dokładny zegar dla tekstów (wcześniej zdarzenia z YouTube przychodziły rzadko).
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTime(time.seconds) }
        }
    }

    private func observe(item: AVPlayerItem) {
        itemObservers.removeAll()
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }

        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.handleItemStatus(status, item: item) }
        })
        itemObservers.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor in self?.handleDuration(d) }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnded() }
        }
    }

    private func syncTimeControlStatus() {
        switch player.timeControlStatus {
        case .playing:
            isPlaying = true
            isBuffering = false
            ended = false
            failures = 0
            stalledTicks = 0
            reloadAttempts = 0
            endBackgroundGrace()
            updateLatency()
        case .waitingToPlayAtSpecifiedRate:
            isPlaying = false
            isBuffering = wantsPlaying
        case .paused:
            isPlaying = false
            isBuffering = wantsPlaying && resolving
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        guard item === player.currentItem, status == .failed else { return }
        handlePlaybackFailure()
    }

    private func handleDuration(_ d: Double) {
        guard d.isFinite, d > 1 else { return }
        if abs(d - clock.duration) > 0.5 {
            clock.duration = d
            if let i = currentIndex, queue.indices.contains(i), queue[i].duration <= 0 { queue[i].duration = d }
        }
        if abs(d - lastNowPlayingDuration) > 0.5 { updateNowPlaying() }
    }

    private func handleTime(_ t: Double) {
        guard t.isFinite, !isSeeking else { return }
        lastTime = t
        clock.time = t
        lyrics.tick(t)
        if let d = player.currentItem?.duration.seconds { handleDuration(d) }
        // Odświeżaj ekran blokady co ~10 s, żeby pozycja nie "uciekała".
        nowPlayingTick += 1
        if nowPlayingTick >= 100 { nowPlayingTick = 0; updateNowPlaying() }
    }

    private func handleItemEnded() {
        ended = true
        isPlaying = false
        trackEnded()
    }

    private func trackEnded() {
        if repeatMode == .one, currentTrack != nil {
            ended = false
            clock.time = 0
            lastTime = 0
            lyrics.tick(0)
            player.seek(to: .zero)
            player.play()
            return
        }
        if let n = nextIndex(auto: true) {
            load(index: n, pushHistory: true)
        } else {
            wantsPlaying = false
            updateNowPlaying()
        }
    }

    private func handleResolveFailure(_ error: Error) {
        resolving = false
        isBuffering = false
        fail(FailureText.describe(error))
    }

    /// The stream address may have expired or been refused - fetch a fresh one once, then give up.
    private func handlePlaybackFailure() {
        guard let t = currentTrack, wantsPlaying else { return }
        if !refreshedURLForCurrent {
            refreshedURLForCurrent = true
            isBuffering = true
            if playingLocalFile {
                // Uszkodzony plik na dysku - usuń go i zagraj ze strumienia.
                let id = t.id
                Task { await AudioCache.shared.remove(id: id) }
            }
            startLoad(track: t, startAt: lastTime, forceRefresh: true)
        } else {
            fail("Nie udało się odtworzyć tego utworu.")
        }
    }

    private func fail(_ message: String) {
        toast.show(message)
        stalledTicks = -6   // give the "skip to next song" below time before the watchdog reacts
        failures += 1
        if failures >= 5 {
            wantsPlaying = false
            isBuffering = false
            return
        }
        let failedID = currentTrack?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self = self, self.currentTrack?.id == failedID, self.wantsPlaying else { return }
            if let n = self.nextIndex(auto: true) { self.load(index: n, pushHistory: true) }
        }
    }

    // MARK: - Audio session, background

    /// Playback category once; re-activate when needed.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setActive(true)
    }

    /// Opóźnienie wyjścia audio (np. Bluetooth ~0,2 s): to, co słychać, jest tyle "spóźnione" względem zegara
    /// odtwarzacza. Teksty muszą to uwzględnić, inaczej wyprzedzają piosenkę.
    private func updateLatency() {
        let latency = AVAudioSession.sharedInstance().outputLatency
        lyrics.setLatency(latency.isFinite ? min(max(latency, 0), 1.0) : 0)
    }

    /// Co 1 s: jeśli ma grać, a nie gra (zerwana sieć, wygasły link), próbuje wznowić, potem pobiera nowy adres.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard wantsPlaying, !interrupted, !ended, let t = currentTrack else { stalledTicks = 0; return }
        if isPlaying { stalledTicks = 0; reloadAttempts = 0; resolveTicks = 0; return }
        if stalledTicks < 0 { stalledTicks += 1; return }
        if resolving {
            // Pobieranie adresu strumienia trwa podejrzanie długo - przerwij i przejdź dalej.
            resolveTicks += 1
            if resolveTicks > 30 {
                resolveTicks = 0
                resolving = false
                loadTask?.cancel()
                fail("YouTube nie odpowiada. Sprawdź internet.")
            }
            return
        }
        resolveTicks = 0
        guard player.currentItem != nil else { return }
        stalledTicks += 1
        if stalledTicks % 5 == 0 {
            // Za długo bez dźwięku: nowy adres strumienia od bieżącej pozycji.
            reloadAttempts += 1
            if reloadAttempts > 4 {
                wantsPlaying = false
                isBuffering = false
                player.pause()
                toast.show("Odtwarzanie zatrzymane. Kliknij play, aby spróbować ponownie.")
                updateNowPlaying()
                return
            }
            isBuffering = true
            startLoad(track: t, startAt: lastTime, forceRefresh: true)
        } else if player.timeControlStatus == .paused {
            activateSession()
            player.play()
        }
    }

    /// Keeps the app running for a few seconds while the next song is being loaded in the background.
    private func beginBackgroundGrace() {
        endBackgroundGrace()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "track-change") { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.endBackgroundGrace()
        }
    }

    private func endBackgroundGrace() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in self?.handleInterruption(type, opts, reason) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.updateLatency()
                self?.handleRouteChange(reason)
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                self?.activateSession()
                if self?.wantsPlaying == true, let t = self?.currentTrack {
                    self?.startLoad(track: t, startAt: self?.lastTime ?? 0)
                }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.activateSession()
                self.updateLatency()
                if self.wantsPlaying && !self.interrupted && self.player.currentItem != nil && self.player.timeControlStatus == .paused {
                    self.player.play()
                }
            }
        })
    }

    private func handleInterruption(_ type: UInt?, _ options: UInt, _ reason: UInt?) {
        guard let raw = type, let t = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if t == .began {
            // Powód 1 = aplikacja została zawieszona, 2 = wyciszony mikrofon: to nie jest prawdziwe przerwanie.
            if let r = reason, r == 1 || r == 2 { return }
            interrupted = true
            wasPlayingBeforeInterruption = wantsPlaying
        } else {
            interrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            if shouldResume && wasPlayingBeforeInterruption { play() }
        }
    }

    private func handleRouteChange(_ reason: UInt?) {
        guard let raw = reason, let r = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if r == .oldDeviceUnavailable && isPlaying { pause() }
    }

    // MARK: - Lock screen / headphones

    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerEngine) -> Void) {
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                if let engine = self { action(engine) }
            }
            return .success
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        bind(c.playCommand) { $0.play() }
        bind(c.pauseCommand) { $0.pause() }
        bind(c.stopCommand) { $0.pause() }
        bind(c.togglePlayPauseCommand) { $0.togglePlayPause() }
        bind(c.nextTrackCommand) { $0.next() }
        bind(c.previousTrackCommand) { $0.previous() }
        c.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: interval) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: -interval) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        applyRemoteEnablement()
    }

    /// Ekran blokady i słuchawki: zawsze przyciski następny / poprzedni utwór (bez przewijania o sekundy).
    func applyRemoteEnablement() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.stopCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        lastNowPlayingDuration = clock.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: max(clock.duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(clock.time, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
