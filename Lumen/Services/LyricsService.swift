import Foundation

struct LyricsCandidate: Identifiable, Codable, Equatable {
    var id: Int
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
    /// "LRCLIB" or "NetEase"
    var source: String?

    var title: String { trackName ?? "" }
    var artist: String { artistName ?? "" }
    var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Unique across providers (ids of different services can be equal).
    var uid: String { "\(source ?? "?")-\(id)" }
}

enum LyricsResult: Equatable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// Time-synced lyrics from two free services at once - LRCLIB (https://lrclib.net) and NetEase Cloud Music -
/// the best matching version (title, artist and above all the same duration as the video) wins.
/// Results are cached on disk, so a song's lyrics are downloaded only once.
actor LyricsService {
    static let shared = LyricsService()

    private var memory: [String: LyricsCandidate] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.httpAdditionalHeaders = ["User-Agent": "MusicPlayer/1.3 (iOS music player)"]
        session = URLSession(configuration: cfg)
    }

    // MARK: Public

    func lyrics(for track: Track) async -> (result: LyricsResult, candidate: LyricsCandidate?) {
        if let c = memory[track.id] ?? readCache(track.id) {
            memory[track.id] = c
            return (LyricsService.result(from: c), c)
        }
        guard let found = await find(track) else { return (.notFound, nil) }
        memory[track.id] = found
        writeCache(found, id: track.id)
        return (LyricsService.result(from: found), found)
    }

    /// Manual search (picker): both services, any version.
    func search(query: String) async -> [LyricsCandidate] {
        async let a = lrclib(["q": query])
        async let b = netease(query: query, guess: nil, duration: 0, limit: 6)
        let all = ((try? await a) ?? []) + (await b)
        return Array(all.filter { $0.hasSynced || $0.hasPlain || $0.instrumental == true }.prefix(30))
    }

    func choose(_ candidate: LyricsCandidate, for trackID: String) {
        memory[trackID] = candidate
        writeCache(candidate, id: trackID)
    }

    func clearCache() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: LyricsService.cacheDir)
    }

    static func result(from c: LyricsCandidate) -> LyricsResult {
        if c.hasSynced {
            let lines = LRCParser.parse(cleanCredits(c.syncedLyrics ?? ""))
            if !lines.isEmpty { return .synced(lines) }
        }
        if c.hasPlain { return .plain(c.plainLyrics ?? "") }
        if c.instrumental == true { return .instrumental }
        return .notFound
    }

    /// NetEase puts "作词 : …" credit lines at the start of the lyrics.
    private static let creditRegex = try? NSRegularExpression(
        pattern: "^\\[[^\\]]*\\]\\s*(作词|作曲|编曲|制作人|制作|录音|混音|母带|监制|词|曲|吉他|贝斯|鼓|和声|企划|OP|SP)\\s*[:：].*$",
        options: [.anchorsMatchLines])

    static func cleanCredits(_ raw: String) -> String {
        guard let re = creditRegex else { return raw }
        return re.stringByReplacingMatches(in: raw, options: [], range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
    }

    // MARK: Matching

    private func find(_ track: Track) async -> LyricsCandidate? {
        var best: (score: Double, cand: LyricsCandidate)? = nil
        let guesses = TitleCleaner.guesses(title: track.title, channel: track.artist)

        for g in guesses {
            async let a = lrclib(["track_name": g.title, "artist_name": g.artist])
            async let b = netease(query: "\(g.artist) \(g.title)", guess: g, duration: track.duration, limit: 3)
            let results = ((try? await a) ?? []) + (await b)
            if let hit = pick(results, guess: g, duration: track.duration), hit.score > (best?.score ?? -1) {
                best = hit
            }
            // Idealne trafienie (synchronizacja + ten sam czas trwania) - nie szukamy dalej.
            if let b = best, b.score >= 128 { break }
        }
        if best == nil || (best?.score ?? 0) < 100, let first = guesses.first {
            let q = "\(first.artist) \(first.title)"
            let results = ((try? await lrclib(["q": q])) ?? [])
            if let hit = pick(results, guess: first, duration: track.duration), hit.score > (best?.score ?? -1) {
                best = hit
            }
        }
        return best?.cand
    }

    private func pick(_ results: [LyricsCandidate], guess: TitleCleaner.Guess, duration: Double) -> (score: Double, cand: LyricsCandidate)? {
        var best: (score: Double, cand: LyricsCandidate)? = nil
        for c in results {
            let titleSim = TitleCleaner.similarity(c.title, guess.title)
            if titleSim < 0.34 { continue }
            let artistSim = TitleCleaner.similarity(c.artist, guess.artist)
            var score = 0.0
            if c.hasSynced { score += 100 } else if c.hasPlain { score += 40 } else if c.instrumental == true { score += 20 } else { continue }
            score += titleSim * 30 + artistSim * 20
            // Wersja tekstu z innym czasem trwania niż film = tekst rozjeżdża się z piosenką (inne tempo / intro).
            // Dlatego zgodność czasu trwania liczy się mocno: ±1,5 s prawie bez kary, a każda sekunda więcej boli.
            if duration > 0, let d = c.duration, d > 0 {
                let diff = abs(d - duration)
                score -= diff <= 1.5 ? diff : 1.5 + min(diff - 1.5, 60) * 3
            }
            if score > (best?.score ?? -Double.infinity) { best = (score, c) }
        }
        return best
    }

    // MARK: LRCLIB

    private func lrclib(_ params: [String: String]) async throws -> [LyricsCandidate] {
        let qs = LyricsService.query(params)
        guard let url = URL(string: "https://lrclib.net/api/search?\(qs)") else { return [] }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        var list = (try? JSONDecoder().decode([LyricsCandidate].self, from: data)) ?? []
        for i in list.indices { list[i].source = "LRCLIB" }
        return list
    }

    // MARK: NetEase

    private struct NESearch: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                struct Album: Decodable { let name: String? }
                let id: Int
                let name: String?
                let duration: Int?
                let artists: [Artist]?
                let album: Album?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    private struct NELyric: Decodable {
        struct Block: Decodable { let lyric: String? }
        let lrc: Block?
    }

    private func neteaseRequest(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("appver=2.0.2", forHTTPHeaderField: "Cookie")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// Search + download of the lyrics of the best few hits.
    private func netease(query: String, guess: TitleCleaner.Guess?, duration: Double, limit: Int) async -> [LyricsCandidate] {
        let qs = LyricsService.query(["s": query, "type": "1", "offset": "0", "limit": "10"])
        guard let data = await neteaseRequest("https://music.163.com/api/search/get/web?\(qs)"),
              let decoded = try? JSONDecoder().decode(NESearch.self, from: data),
              let songs = decoded.result?.songs, !songs.isEmpty else { return [] }

        // Rank the hits before downloading lyrics (one request per hit).
        let ranked = songs.map { song -> (NESearch.Result.Song, Double) in
            let artist = (song.artists ?? []).compactMap { $0.name }.joined(separator: " ")
            var score = 0.0
            if let g = guess {
                score += TitleCleaner.similarity(song.name ?? "", g.title) * 30 + TitleCleaner.similarity(artist, g.artist) * 20
            }
            if duration > 0, let ms = song.duration, ms > 0 {
                score -= min(abs(Double(ms) / 1000 - duration), 60)
            }
            return (song, score)
        }.sorted { $0.1 > $1.1 }.prefix(limit)

        var out: [LyricsCandidate] = []
        await withTaskGroup(of: LyricsCandidate?.self) { group in
            for (song, _) in ranked {
                group.addTask { await self.neteaseLyrics(song) }
            }
            for await c in group { if let c = c { out.append(c) } }
        }
        return out
    }

    private func neteaseLyrics(_ song: NESearch.Result.Song) async -> LyricsCandidate? {
        let qs = LyricsService.query(["id": String(song.id), "lv": "1", "kv": "1", "tv": "-1"])
        guard let data = await neteaseRequest("https://music.163.com/api/song/lyric?\(qs)"),
              let decoded = try? JSONDecoder().decode(NELyric.self, from: data),
              let raw = decoded.lrc?.lyric,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var c = LyricsCandidate(
            id: song.id,
            trackName: song.name,
            artistName: (song.artists ?? []).compactMap { $0.name }.joined(separator: ", "),
            albumName: song.album?.name,
            duration: song.duration.map { Double($0) / 1000 },
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: nil,
            source: "NetEase")
        let cleaned = LyricsService.cleanCredits(raw)
        if !LRCParser.parse(cleaned).isEmpty { c.syncedLyrics = cleaned } else { c.plainLyrics = cleaned }
        return c
    }

    // MARK: Helpers

    private static func query(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    // MARK: Disk cache

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Lumen/Lyrics", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL {
        LyricsService.cacheDir.appendingPathComponent("\(id).json")
    }

    private func readCache(_ id: String) -> LyricsCandidate? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? JSONDecoder().decode(LyricsCandidate.self, from: data)
    }

    private func writeCache(_ c: LyricsCandidate, id: String) {
        try? FileManager.default.createDirectory(at: LyricsService.cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: fileURL(id), options: .atomic) }
    }
}
