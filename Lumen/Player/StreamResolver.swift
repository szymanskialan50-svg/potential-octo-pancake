import Foundation
import YouTubeKit

enum StreamError: LocalizedError {
    case noPlayableStream

    var errorDescription: String? { "Nie znaleziono strumienia audio dla tego filmu." }
}

/// Zamienia identyfikator filmu na bezpośredni adres strumienia audio (przez YouTubeKit).
/// Adresy są trzymane w pamięci do czasu wygaśnięcia, a następny utwór można pobrać z wyprzedzeniem,
/// więc przejście do kolejnej piosenki w tle jest natychmiastowe i nie wymaga czekania na sieć.
struct ResolvedStream: Sendable {
    let url: URL
    /// "m4a" (czyste audio) albo "mp4" (awaryjnie strumień z obrazem).
    let ext: String
}

actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let stream: ResolvedStream
        let expires: Date
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<ResolvedStream, Error>] = [:]

    /// Zwraca adres strumienia audio. `forceRefresh` pomija pamięć podręczną (np. po wygaśnięciu linku).
    func resolve(_ id: String, forceRefresh: Bool = false) async throws -> ResolvedStream {
        if !forceRefresh {
            if let entry = cache[id], entry.expires > Date() { return entry.stream }
            if let running = inflight[id] { return try await running.value }
        } else {
            cache[id] = nil
            inflight[id]?.cancel()
            inflight[id] = nil
        }

        let task = Task { try await StreamResolver.extract(videoID: id) }
        inflight[id] = task
        do {
            let stream = try await task.value
            inflight[id] = nil
            cache[id] = Entry(stream: stream, expires: StreamResolver.expiry(of: stream.url))
            trimCache()
            return stream
        } catch {
            inflight[id] = nil
            throw error
        }
    }

    /// Rozgrzewka przy starcie: pobiera skrypt odtwarzacza YouTube, żeby pierwsza piosenka ruszyła szybciej.
    func warmUp() async {
        _ = try? await YouTube(videoID: "dQw4w9WgXcQ", methods: [.local]).streams
    }

    func clear() {
        cache.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
    }

    private func trimCache() {
        guard cache.count > 12 else { return }
        let oldest = cache.sorted { $0.value.expires < $1.value.expires }.prefix(cache.count - 12)
        for (key, _) in oldest { cache[key] = nil }
    }

    // MARK: - Extraction

    private static func extract(videoID: String) async throws -> ResolvedStream {
        let video = YouTube(videoID: videoID, methods: [.local, .remote])
        let streams = try await video.streams

        // 1) Czyste audio AAC (m4a) o najwyższym bitrate - najmniej danych i najlepsza jakość.
        let m4a = streams
            .filterAudioOnly()
            .filter { $0.isNativelyPlayable && $0.fileExtension == .m4a }
            .highestAudioBitrateStream()
        if let s = m4a { return ResolvedStream(url: s.url, ext: "m4a") }

        // 2) Jakiekolwiek audio, które iOS odtworzy natywnie.
        let anyAudio = streams
            .filterAudioOnly()
            .filter { $0.isNativelyPlayable }
            .highestAudioBitrateStream()
        if let s = anyAudio { return ResolvedStream(url: s.url, ext: "m4a") }

        // 3) Awaryjnie: strumień z obrazem w najniższej rozdzielczości (obraz i tak nie jest pokazywany).
        let progressive = streams
            .filterVideoAndAudio()
            .filter { $0.isNativelyPlayable }
            .lowestResolutionStream()
        if let s = progressive { return ResolvedStream(url: s.url, ext: "mp4") }

        throw StreamError.noPlayableStream
    }

    /// Adresy googlevideo mają parametr `expire` (czas UNIX). Odświeżamy je z zapasem 10 minut.
    private static func expiry(of url: URL) -> Date {
        let fallback = Date().addingTimeInterval(2 * 3600)
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "expire" })?.value,
              let epoch = TimeInterval(raw) else { return fallback }
        let date = Date(timeIntervalSince1970: epoch - 600)
        return date > Date() ? date : fallback
    }
}

/// Polskie komunikaty dla błędów YouTubeKit.
enum FailureText {
    static func describe(_ error: Error) -> String {
        if let e = error as? YouTubeKitError {
            switch e {
            case .videoPrivate: return "Ten film jest prywatny."
            case .videoUnavailable, .recordingUnavailable: return "Ten film jest niedostępny lub został usunięty."
            case .videoAgeRestricted: return "Ten film ma ograniczenie wiekowe i nie da się go odtworzyć."
            case .membersOnly: return "Ten film jest tylko dla członków kanału."
            case .liveStreamError: return "Transmisje na żywo nie są obsługiwane."
            case .videoRegionBlocked: return "Ten film jest zablokowany w Twoim regionie."
            default: return "Nie udało się pobrać strumienia z YouTube."
            }
        }
        if error is StreamError { return "Nie znaleziono strumienia audio dla tego filmu." }
        if (error as NSError).domain == NSURLErrorDomain { return "Brak połączenia z YouTube. Sprawdź internet." }
        return "Nie udało się pobrać strumienia z YouTube."
    }
}
