import SwiftUI
import UIKit

// MARK: - Color <-> hex

extension Color {
    /// "RRGGBB" or "RRGGBBAA"
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 6 { s += "FF" }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFFFF
        self.init(.sRGB,
                  red: Double((v >> 24) & 0xFF) / 255,
                  green: Double((v >> 16) & 0xFF) / 255,
                  blue: Double((v >> 8) & 0xFF) / 255,
                  opacity: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()),
                      Int((b * 255).rounded()), Int((a * 255).rounded()))
    }
}

// MARK: - Settings

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case blur, color, image, black, white
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blur: return "Okładka utworu"
        case .color: return "Kolor / gradient"
        case .image: return "Własne zdjęcie"
        case .black: return "Czarne"
        case .white: return "Białe"
        }
    }
}

enum LockScreenSkip: String, Codable, CaseIterable, Identifiable {
    case track, seconds
    var id: String { rawValue }
    var title: String { self == .track ? "Następny / poprzedni utwór" : "Przewijanie o 10 sekund" }
}

struct SettingsData: Codable, Equatable {
    var apiKey: String = ""
    var theme: ThemeMode = .blur
    var dim: Double = 0.25
    var blurInactiveLyrics: Bool = true
    var lockScreenSkip: LockScreenSkip = .track
    var skipInterval: Double = 10
    var lyricsOffsets: [String: Double] = [:]
    /// Rozciągnięcie czasu tekstu (1.0 = bez zmian), osobno dla każdej piosenki.
    var lyricsStretch: [String: Double] = [:]
    var guideSeen: Bool = false

    // Kolory (pusty = automatycznie, zależnie od tła)
    var inkHex: String = ""
    var accentHex: String = ""
    var lyricsHex: String = ""

    // Tło
    var artworkBlur: Bool = true
    var backgroundColorHex: String = "2B2B6B"
    var backgroundColor2Hex: String = "07070F"
    var backgroundGradient: Bool = true
    var imageBlur: Bool = true
    var imageBlurRadius: Double = 18

    init() {}

    // Old saved settings (with options that no longer exist) still load; missing keys use defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        theme = (try? c.decode(ThemeMode.self, forKey: .theme)) ?? .blur
        dim = (try? c.decode(Double.self, forKey: .dim)) ?? 0.25
        blurInactiveLyrics = (try? c.decode(Bool.self, forKey: .blurInactiveLyrics)) ?? true
        lockScreenSkip = (try? c.decode(LockScreenSkip.self, forKey: .lockScreenSkip)) ?? .track
        skipInterval = (try? c.decode(Double.self, forKey: .skipInterval)) ?? 10
        lyricsOffsets = (try? c.decode([String: Double].self, forKey: .lyricsOffsets)) ?? [:]
        lyricsStretch = (try? c.decode([String: Double].self, forKey: .lyricsStretch)) ?? [:]
        guideSeen = (try? c.decode(Bool.self, forKey: .guideSeen)) ?? false
        inkHex = (try? c.decode(String.self, forKey: .inkHex)) ?? ""
        accentHex = (try? c.decode(String.self, forKey: .accentHex)) ?? ""
        lyricsHex = (try? c.decode(String.self, forKey: .lyricsHex)) ?? ""
        artworkBlur = (try? c.decode(Bool.self, forKey: .artworkBlur)) ?? true
        backgroundColorHex = (try? c.decode(String.self, forKey: .backgroundColorHex)) ?? "2B2B6B"
        backgroundColor2Hex = (try? c.decode(String.self, forKey: .backgroundColor2Hex)) ?? "07070F"
        backgroundGradient = (try? c.decode(Bool.self, forKey: .backgroundGradient)) ?? true
        imageBlur = (try? c.decode(Bool.self, forKey: .imageBlur)) ?? true
        imageBlurRadius = (try? c.decode(Double.self, forKey: .imageBlurRadius)) ?? 18
    }
}



final class AppSettings: ObservableObject {
    @Published var data: SettingsData {
        didSet { if data != oldValue { scheduleSave() } }
    }
    /// Zdjęcie wybrane jako tło (przeskalowane, zapisane w Application Support).
    @Published private(set) var backgroundImage: UIImage? = nil

    private static let key = "lumen.settings.v1"
    private var saveWork: DispatchWorkItem?

    init() {
        var d = SettingsData()
        if let raw = UserDefaults.standard.data(forKey: AppSettings.key),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: raw) {
            d = decoded
        }
        // The YouTube API key is built into the app (no field in Settings any more).
        if let embedded = Bundle.main.object(forInfoDictionaryKey: "YouTubeAPIKey") as? String {
            let key = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !key.contains("$(") { d.apiKey = key }
        }
        data = d
        backgroundImage = AppSettings.loadBackgroundImage()
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.flushSave()
        }
    }

    /// Settings change on every slider tick; writing them each time made dragging laggy.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        save()
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: AppSettings.key)
        }
    }

    var api: YouTubeAPI { YouTubeAPI(apiKey: data.apiKey) }
    /// A light background needs dark text, so the whole app switches to the light appearance.
    var colorScheme: ColorScheme {
        switch data.theme {
        case .white: return .light
        case .color:
            let a = UIColor(Color(hex: data.backgroundColorHex)).luminance
            let b = data.backgroundGradient ? UIColor(Color(hex: data.backgroundColor2Hex)).luminance : a
            return (a + b) / 2 > 0.6 ? .light : .dark
        default: return .dark
        }
    }

    // MARK: Colours

    /// Main colour of texts and icons ("" = automatic: white on dark, black on light).
    var ink: Color { data.inkHex.isEmpty ? Color.primary : Color(hex: data.inkHex) }
    /// Accent: sliders, active buttons, switches, menus.
    var accent: Color { data.accentHex.isEmpty ? ink : Color(hex: data.accentHex) }
    /// Lyrics colour.
    var lyricsInk: Color { data.lyricsHex.isEmpty ? ink : Color(hex: data.lyricsHex) }

    func resetColors() {
        data.inkHex = ""
        data.accentHex = ""
        data.lyricsHex = ""
    }

    // MARK: Background image

    private static var backgroundImageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("background.jpg")
    }

    private static func loadBackgroundImage() -> UIImage? {
        guard let data = try? Data(contentsOf: backgroundImageURL) else { return nil }
        return UIImage(data: data)
    }

    func setBackgroundImage(_ raw: Data) {
        guard let image = UIImage(data: raw) else { return }
        let small = ArtworkLoader.downscale(image, maxSide: 1800)
        if let jpeg = small.jpegData(compressionQuality: 0.88) {
            try? jpeg.write(to: AppSettings.backgroundImageURL, options: .atomic)
        }
        backgroundImage = small
        data.theme = .image
    }

    func removeBackgroundImage() {
        try? FileManager.default.removeItem(at: AppSettings.backgroundImageURL)
        backgroundImage = nil
        if data.theme == .image { data.theme = .blur }
    }

    func lyricsStretch(for trackID: String) -> Double { data.lyricsStretch[trackID] ?? 1 }
    func setLyricsStretch(_ value: Double, for trackID: String) {
        if abs(value - 1) < 0.0005 { data.lyricsStretch.removeValue(forKey: trackID) }
        else { data.lyricsStretch[trackID] = value }
    }

    // Lyrics timing offset per track
    func lyricsOffset(for trackID: String) -> Double { data.lyricsOffsets[trackID] ?? 0 }
    func setLyricsOffset(_ value: Double, for trackID: String) {
        if abs(value) < 0.001 { data.lyricsOffsets.removeValue(forKey: trackID) }
        else { data.lyricsOffsets[trackID] = value }
    }
}

// MARK: - Library (playlists)

final class LibraryStore: ObservableObject {
    @Published var playlists: [Playlist] = [] {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        if let raw = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Playlist].self, from: raw) {
            playlists = list
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(playlists) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first(where: { $0.id == id }) }

    @discardableResult
    func create(name: String, tracks: [Track] = []) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.id).inserted }
        let p = Playlist(name: clean.isEmpty ? "Nowa playlista" : clean, tracks: unique)
        playlists.insert(p, at: 0)
        return p
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = clean
    }

    func delete(at offsets: IndexSet) { playlists.remove(atOffsets: offsets) }

    func delete(id: UUID) { playlists.removeAll(where: { $0.id == id }) }

    /// Adds tracks (skipping ones already in the playlist). Returns how many were added.
    @discardableResult
    func add(_ tracks: [Track], to id: UUID) -> Int {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var existing = Set(playlists[i].tracks.map { $0.id })
        var added: [Track] = []
        for t in tracks where !existing.contains(t.id) {
            existing.insert(t.id)
            added.append(t)
        }
        playlists[i].tracks.append(contentsOf: added)
        return added.count
    }

    func remove(at offsets: IndexSet, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int, in id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Toast

final class ToastCenter: ObservableObject {
    @Published var message: String? = nil
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.message = nil }
        }
    }
}

extension UIColor {
    /// Perceived brightness 0...1.
    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
    }
}
