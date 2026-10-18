import Foundation

/// Trwały zapis piosenek na dysku. Pierwsze odtworzenie leci ze strumienia, a w tle utwór jest pobierany
/// do końca i zostaje na stałe - każde kolejne odtworzenie startuje natychmiast i działa bez internetu.
actor AudioCache {
    static let shared = AudioCache()

    private let dir: URL
    private let session: URLSession
    private var inflight: [String: Task<URL?, Never>] = [:]
    private var slots = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// yt-dlp pobiera w kawałkach ~10 MB, bo YouTube dławi długie, pojedyncze żądania.
    private static let chunk = 9_437_184

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // duże pliki nie lecą do iCloud
        try? folder.setResourceValues(values)
        dir = folder
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    // MARK: Lookup

    /// Pobrany plik utworu (jeśli już jest na dysku).
    func localURL(for id: String) -> URL? {
        for ext in ["m4a", "mp4"] {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 50_000 {
                return url
            }
        }
        return nil
    }

    func remove(id: String) {
        for ext in ["m4a", "mp4"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }

    func stats() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var count = 0
        var bytes: Int64 = 0
        for f in files where f.pathExtension == "m4a" || f.pathExtension == "mp4" {
            count += 1
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (count, bytes)
    }

    // MARK: Download

    /// Upewnia się, że utwór jest na dysku (pobiera go, jeśli trzeba). Zwraca adres pliku.
    @discardableResult
    func ensure(_ id: String) async -> URL? {
        if let local = localURL(for: id) { return local }
        if let running = inflight[id] { return await running.value }
        let task = Task<URL?, Never> { await self.fetch(id) }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        return result
    }

    private func acquire() async {
        if slots < 2 { slots += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { slots -= 1 } else { waiters.removeFirst().resume() }
    }

    private func fetch(_ id: String) async -> URL? {
        await acquire()
        defer { release() }
        if let local = localURL(for: id) { return local }
        for attempt in 0..<2 {
            guard let stream = try? await StreamResolver.shared.resolve(id, forceRefresh: attempt > 0) else { continue }
            let target = dir.appendingPathComponent("\(id).\(stream.ext)")
            if await download(stream.url, to: target) { return target }
        }
        return nil
    }

    private func download(_ remote: URL, to target: URL) async -> Bool {
        let part = target.appendingPathExtension("part")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else { return false }
        defer { try? handle.close() }

        var offset = 0
        var total = Int.max
        while offset < total {
            if Task.isCancelled { try? fm.removeItem(at: part); return false }
            var request = URLRequest(url: remote)
            request.setValue("bytes=\(offset)-\(offset + AudioCache.chunk - 1)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { try? fm.removeItem(at: part); return false }
            switch http.statusCode {
            case 206:
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = range.lastIndex(of: "/"), let t = Int(range[range.index(after: slash)...]) {
                    total = t
                } else if data.count < AudioCache.chunk {
                    total = offset + data.count
                }
            case 200:
                total = data.count     // serwer zignorował zakres i przysłał całość
            default:
                try? fm.removeItem(at: part)
                return false
            }
            if data.isEmpty { try? fm.removeItem(at: part); return false }
            do { try handle.write(contentsOf: data) } catch { try? fm.removeItem(at: part); return false }
            offset += data.count
        }
        try? handle.close()
        guard offset > 50_000 else { try? fm.removeItem(at: part); return false }
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: part, to: target) } catch { try? fm.removeItem(at: part); return false }
        return true
    }
}
