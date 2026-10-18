import Foundation

enum YouTubeAPIError: LocalizedError {
    case missingKey
    case api(String)
    case network(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Wyszukiwanie niedostępne: ta wersja aplikacji nie ma klucza YouTube API."
        case .api(let m): return m
        case .network(let m): return "Błąd sieci: \(m)"
        case .notFound: return "Nic nie znaleziono pod tym linkiem (może być prywatny, usunięty lub z zablokowanym osadzaniem)."
        }
    }
}

/// Thin client for the YouTube Data API v3 (search, videos, playlists).
struct YouTubeAPI {
    var apiKey: String

    private static let base = "https://www.googleapis.com/youtube/v3"
    private static let queryAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    // MARK: Response models

    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            let id: ID
        }
        let items: [Item]
    }
    private struct VideosResponse: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let title: String; let channelTitle: String }
            struct Content: Decodable { let duration: String? }
            struct Status: Decodable { let embeddable: Bool? }
            let id: String
            let snippet: Snippet?
            let contentDetails: Content?
            let status: Status?
        }
        let items: [Item]
    }
    private struct PlaylistItemsResponse: Decodable {
        struct Item: Decodable {
            struct Content: Decodable { let videoId: String? }
            let contentDetails: Content?
        }
        let items: [Item]
        let nextPageToken: String?
    }
    private struct PlaylistsResponse: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable { let title: String }
            let snippet: Snippet
        }
        let items: [Item]
    }
    private struct OEmbed: Decodable {
        let title: String
        let author_name: String?
    }

    // MARK: Public API

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func search(_ query: String) async throws -> [Track] {
        let r = try await get("/search", [
            "part": "snippet", "type": "video", "maxResults": "25", "q": query
        ], as: SearchResponse.self)
        let ids = r.items.compactMap { $0.id.videoId }
        if ids.isEmpty { return [] }
        return try await videos(ids: ids, embeddableOnly: false)
    }

    func videos(ids: [String], embeddableOnly: Bool) async throws -> [Track] {
        var result: [Track] = []
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 50, ids.count)])
            index += 50
            let r = try await get("/videos", [
                "part": "snippet,contentDetails,status",
                "id": chunk.joined(separator: ","),
                "maxResults": "50"
            ], as: VideosResponse.self)
            var byID: [String: Track] = [:]
            for item in r.items {
                if embeddableOnly, item.status?.embeddable == false { continue }
                guard let sn = item.snippet else { continue }
                byID[item.id] = Track(
                    id: item.id,
                    title: HTMLEntities.decode(sn.title),
                    artist: TitleCleaner.cleanChannel(sn.channelTitle),
                    duration: ISODuration.seconds(item.contentDetails?.duration ?? ""))
            }
            for id in chunk {
                if let t = byID[id] { result.append(t) }
            }
        }
        return result
    }

    func video(id: String) async throws -> Track {
        if !hasKey { return try await YouTubeAPI.oEmbedTrack(id: id) }
        let list = try await videos(ids: [id], embeddableOnly: false)
        guard let t = list.first else { throw YouTubeAPIError.notFound }
        return t
    }

    func playlist(id: String) async throws -> (title: String, tracks: [Track], skipped: Int) {
        let info = try await get("/playlists", ["part": "snippet", "id": id], as: PlaylistsResponse.self)
        guard let title = info.items.first?.snippet.title else { throw YouTubeAPIError.notFound }
        var ids: [String] = []
        var token: String? = nil
        var pages = 0
        repeat {
            var q = ["part": "contentDetails", "playlistId": id, "maxResults": "50"]
            if let t = token { q["pageToken"] = t }
            let page = try await get("/playlistItems", q, as: PlaylistItemsResponse.self)
            ids += page.items.compactMap { $0.contentDetails?.videoId }
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 20
        let tracks = try await videos(ids: ids, embeddableOnly: false)
        return (HTMLEntities.decode(title), tracks, max(0, ids.count - tracks.count))
    }

    /// Works without an API key (single videos only, no duration).
    static func oEmbedTrack(id: String) async throws -> Track {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        let enc = watch.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? watch
        guard let url = URL(string: "https://www.youtube.com/oembed?format=json&url=\(enc)") else {
            throw YouTubeAPIError.notFound
        }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(from: url) }
        catch { throw YouTubeAPIError.network(error.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              let o = try? JSONDecoder().decode(OEmbed.self, from: result.0) else {
            throw YouTubeAPIError.notFound
        }
        return Track(id: id, title: HTMLEntities.decode(o.title),
                     artist: TitleCleaner.cleanChannel(o.author_name ?? ""), duration: 0)
    }

    // MARK: Networking

    private func get<T: Decodable>(_ path: String, _ query: [String: String], as type: T.Type) async throws -> T {
        guard hasKey else { throw YouTubeAPIError.missingKey }
        var pairs = query
        pairs["key"] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let qs = pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: YouTubeAPI.queryAllowed) ?? "")"
        }.joined(separator: "&")
        guard let url = URL(string: YouTubeAPI.base + path + "?" + qs) else {
            throw YouTubeAPIError.api("Nie udało się utworzyć zapytania.")
        }
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(from: url) }
        catch { throw YouTubeAPIError.network(error.localizedDescription) }
        let (data, response) = result
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message ?? "HTTP \(http.statusCode)"
            throw YouTubeAPIError.api(YouTubeAPI.friendly(msg, http.statusCode))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw YouTubeAPIError.api("Nieoczekiwana odpowiedź z YouTube.") }
    }

    private static func friendly(_ message: String, _ code: Int) -> String {
        let l = message.lowercased()
        if l.contains("api key not valid") || l.contains("api_key_invalid") {
            return "Klucz YouTube API wbudowany w aplikację jest nieprawidłowy."
        }
        if l.contains("quota") {
            return "Dzienny limit YouTube API został wykorzystany. Odnowi się o północy czasu pacyficznego (rano w Polsce)."
        }
        if l.contains("has not been used") || l.contains("is disabled") || l.contains("accessnotconfigured") {
            return "Włącz „YouTube Data API v3” w swoim projekcie Google Cloud i spróbuj ponownie."
        }
        if code == 404 { return "Nie znaleziono playlisty lub filmu (może być prywatny lub usunięty)." }
        return message
    }
}
