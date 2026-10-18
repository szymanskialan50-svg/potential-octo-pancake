import Foundation

/// Holds the lyrics of the current track and which line is active.
@MainActor
final class LyricsController: ObservableObject {
    enum Phase: Equatable { case idle, loading, synced, plain, instrumental, notFound }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainText: String = ""
    @Published private(set) var activeIndex: Int = -1
    /// Positive = lyrics appear earlier, negative = later (seconds).
    @Published private(set) var offset: Double = 0
    /// Time stretch of the lyrics (1.0 = as is). Above 1 the lyrics run slower, below 1 faster.
    @Published private(set) var stretch: Double = 1
    /// The version that is currently shown (for the picker).
    @Published private(set) var current: LyricsCandidate? = nil

    private var trackID: String?
    private var loadTask: Task<Void, Never>?
    private var lastTime: Double = 0
    /// Output latency of the current audio route (seconds). What the user hears is this much behind the
    /// player clock (Bluetooth: ~0.2 s), so the lyrics are held back by the same amount.
    private var latency: Double = 0

    func load(track: Track, offset: Double, stretch: Double = 1) {
        trackID = track.id
        self.offset = offset
        self.stretch = stretch
        current = nil
        loadTask?.cancel()
        phase = .loading
        lines = []
        plainText = ""
        activeIndex = -1
        loadTask = Task { [weak self] in
            let found = await LyricsService.shared.lyrics(for: track)
            guard let self = self, !Task.isCancelled, self.trackID == track.id else { return }
            self.current = found.candidate
            self.apply(found.result)
        }
    }

    func setOffset(_ value: Double) {
        offset = value
        tick(lastTime)
    }

    func setStretch(_ value: Double) {
        stretch = min(max(value, 0.8), 1.25)
        tick(lastTime)
    }

    func setLatency(_ value: Double) {
        latency = value
        tick(lastTime)
    }

    func choose(_ candidate: LyricsCandidate, for track: Track) {
        Task { [weak self] in
            await LyricsService.shared.choose(candidate, for: track.id)
            guard let self = self, self.trackID == track.id else { return }
            self.current = candidate
            self.apply(LyricsService.result(from: candidate))
        }
    }

    func tick(_ time: Double) {
        lastTime = time
        guard phase == .synced else { return }
        let idx = LRCParser.activeIndex(in: lines, at: (time - latency) / stretch + offset)
        if idx != activeIndex { activeIndex = idx }
    }

    private func apply(_ result: LyricsResult) {
        switch result {
        case .synced(let l):
            lines = l
            phase = .synced
            activeIndex = -1
            tick(lastTime)
        case .plain(let text):
            plainText = text
            phase = .plain
        case .instrumental:
            phase = .instrumental
        case .notFound:
            phase = .notFound
        }
    }
}
