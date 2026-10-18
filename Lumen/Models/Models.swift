import Foundation

struct Track: Identifiable, Codable, Hashable {
    var id: String          // YouTube video id
    var title: String
    var artist: String
    var duration: Double    // seconds, 0 if unknown

    var artworkURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)") ?? URL(string: "https://www.youtube.com")! }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track] = []
}

enum Pl {
    /// Polska odmiana: 1 piosenka, 2-4 piosenki, 5+ piosenek.
    static func songs(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if n == 1 { return "1 piosenka" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) piosenki" }
        return "\(n) piosenek"
    }
}

enum Fmt {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let t = Int(seconds.rounded(.down))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Lyrics (LRC)

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum LRCParser {
    /// Parses "[mm:ss.xx] text" lines (multiple time tags, offset tag and word tags supported).
    static func parse(_ raw: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        var offset = 0.0
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            var rest = rawLine.trimmingCharacters(in: .whitespaces)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...])
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(value) { offset = ms / 1000.0 }
                }
            }
            if times.isEmpty { continue }
            let text = collapse(stripWordTags(rest))
            for t in times { entries.append((t, text)) }
        }
        let ordered = entries.enumerated().sorted { a, b in
            a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0
        }.map { $0.element }
        var lines: [LyricLine] = []
        for (i, e) in ordered.enumerated() {
            lines.append(LyricLine(id: i, time: max(0, e.0 - offset), text: e.1))
        }
        return lines
    }

    static func parseTimestamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let s = part.replacingOccurrences(of: ",", with: ".")
            guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(s) else { return nil }
            if i == parts.count - 1 { total += v } else { total = (total + v) * 60 }
        }
        return total
    }

    /// Index of the line that is active at `time` (-1 before the first line).
    static func activeIndex(in lines: [LyricLine], at time: Double) -> Int {
        guard let first = lines.first, time >= first.time else { return -1 }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "<", let close = s[i...].firstIndex(of: ">") {
                let inner = String(s[s.index(after: i)..<close])
                if parseTimestamp(inner) != nil {
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func collapse(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
