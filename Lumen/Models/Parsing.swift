import Foundation

// MARK: - YouTube links

enum YouTubeLink: Equatable {
    case video(String)
    case playlist(String)
    case videoInPlaylist(video: String, playlist: String)
}

enum YouTubeURL {
    private static func idChars(_ s: String) -> Bool {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func isVideoID(_ s: String) -> Bool { s.count == 11 && idChars(s) }
    static func isPlaylistID(_ s: String) -> Bool { (10...64).contains(s.count) && idChars(s) }

    static func parse(_ text: String, allowBareID: Bool = false) -> YouTubeLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains(".") && !trimmed.contains("/") {
            guard allowBareID else { return nil }
            if isVideoID(trimmed) { return .video(trimmed) }
            let prefixes = ["PL", "UU", "FL", "OL", "LL", "RD"]
            if isPlaylistID(trimmed), prefixes.contains(where: { trimmed.hasPrefix($0) }) { return .playlist(trimmed) }
            return nil
        }

        var s = trimmed
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let comps = URLComponents(string: s), let host = comps.host?.lowercased() else { return nil }
        let isYouTube = host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
        guard isYouTube else { return nil }

        let items = comps.queryItems ?? []
        let vParam = items.first(where: { $0.name == "v" })?.value
        let listParam = items.first(where: { $0.name == "list" })?.value
        let pathParts = comps.path.split(separator: "/").map(String.init)

        var video: String? = nil
        if host == "youtu.be" {
            video = pathParts.first
        } else if let v = vParam {
            video = v
        } else if pathParts.count >= 2, ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
            video = pathParts[1]
        }

        var validVideo: String? = nil
        if let v = video, isVideoID(v) { validVideo = v }
        var validList: String? = nil
        if let l = listParam, isPlaylistID(l) { validList = l }

        switch (validVideo, validList) {
        case (let v?, let l?): return .videoInPlaylist(video: v, playlist: l)
        case (let v?, nil): return .video(v)
        case (nil, let l?): return .playlist(l)
        default: return nil
        }
    }
}

// MARK: - ISO 8601 duration ("PT4M13S")

enum ISODuration {
    static func seconds(_ s: String) -> Double {
        guard s.hasPrefix("P") else { return 0 }
        var total = 0.0
        var num = ""
        var inTime = false
        for ch in s.dropFirst() {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." { num.append(ch); continue }
            let v = Double(num) ?? 0
            num = ""
            switch ch {
            case "W": total += v * 604_800
            case "D": total += v * 86_400
            case "H": total += v * 3_600
            case "M": total += inTime ? v * 60 : v * 2_592_000
            case "S": total += v
            default: break
            }
        }
        return total
    }
}

// MARK: - HTML entities (YouTube search titles are escaped)

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let body = String(s[s.index(after: i)..<semi])
                if let rep = replacement(for: body) {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func replacement(for body: String) -> String? {
        if body.hasPrefix("#") {
            let num = body.dropFirst()
            var code: UInt32? = nil
            if num.hasPrefix("x") || num.hasPrefix("X") {
                code = UInt32(num.dropFirst(), radix: 16)
            } else {
                code = UInt32(num)
            }
            if let c = code, let scalar = Unicode.Scalar(c) { return String(Character(scalar)) }
            return nil
        }
        return named[body]
    }
}

// MARK: - Title cleaning for lyric lookups

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum TitleCleaner {
    struct Guess: Equatable {
        let artist: String
        let title: String
    }

    private static let bracketNoise = try? NSRegularExpression(
        pattern: "[\\(\\[\\{][^\\)\\]\\}]*(official|lyric|audio|video|visuali[sz]er|\\bhd\\b|\\bhq\\b|4k|\\bmv\\b|m/v|clip|remaster|explicit|full album)[^\\)\\]\\}]*[\\)\\]\\}]",
        options: [.caseInsensitive])

    private static let trailingNoise = try? NSRegularExpression(
        pattern: "\\s*[-–—|]?\\s*(official\\s+(music\\s+)?(video|audio|lyric\\s+video)|lyric\\s+video|lyrics|visuali[sz]er)\\s*$",
        options: [.caseInsensitive])

    static func stripNoise(_ s: String) -> String {
        var t = s
        for re in [bracketNoise, trailingNoise] {
            if let re = re {
                t = re.stringByReplacingMatches(in: t, options: [], range: NSRange(t.startIndex..., in: t), withTemplate: "")
            }
        }
        if let r = t.range(of: " | ") { t = String(t[..<r.lowerBound]) }
        let squeezed = t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return squeezed.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·"))
    }

    static func cleanChannel(_ raw: String) -> String {
        var c = HTMLEntities.decode(raw).trimmed
        if c.hasSuffix(" - Topic") { c = String(c.dropLast(8)) }
        let lower = c.lowercased()
        if lower.hasSuffix("vevo"), c.count > 4 { c = String(c.dropLast(4)) }
        return c.trimmed
    }

    /// Ordered guesses of (artist, title) for a YouTube video.
    static func guesses(title rawTitle: String, channel rawChannel: String) -> [Guess] {
        let title = stripNoise(HTMLEntities.decode(rawTitle))
        let channel = cleanChannel(rawChannel)
        var out: [Guess] = []
        for sep in [" - ", " – ", " — ", " ~ "] {
            if let r = title.range(of: sep) {
                let left = String(title[..<r.lowerBound]).trimmed
                let right = String(title[r.upperBound...]).trimmed
                if !left.isEmpty && !right.isEmpty {
                    out.append(Guess(artist: left, title: right))
                    out.append(Guess(artist: right, title: left))
                    break
                }
            }
        }
        out.append(Guess(artist: channel, title: title))
        var unique: [Guess] = []
        for g in out where !unique.contains(g) && !g.title.isEmpty { unique.append(g) }
        return Array(unique.prefix(4))
    }

    static func tokens(_ s: String) -> Set<String> {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let parts = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0) }
        return Set(parts.filter { !$0.isEmpty })
    }

    /// Jaccard similarity of word sets, 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a)
        let y = tokens(b)
        if x.isEmpty || y.isEmpty { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
