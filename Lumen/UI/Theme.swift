import SwiftUI

// Kolory ustawiane przez użytkownika, przekazywane przez środowisko SwiftUI do wszystkich ekranów.

private struct InkKey: EnvironmentKey { static let defaultValue: Color = .primary }
private struct AccentInkKey: EnvironmentKey { static let defaultValue: Color = .primary }
private struct LyricsInkKey: EnvironmentKey { static let defaultValue: Color = .primary }

extension EnvironmentValues {
    /// Główny kolor tekstów i ikon.
    var ink: Color {
        get { self[InkKey.self] }
        set { self[InkKey.self] = newValue }
    }
    /// Kolor akcentu (suwaki, aktywne przyciski, przełączniki).
    var accentInk: Color {
        get { self[AccentInkKey.self] }
        set { self[AccentInkKey.self] = newValue }
    }
    /// Kolor tekstu piosenki.
    var lyricsInk: Color {
        get { self[LyricsInkKey.self] }
        set { self[LyricsInkKey.self] = newValue }
    }
}

extension View {
    func appColors(_ settings: AppSettings) -> some View {
        self
            .environment(\.ink, settings.ink)
            .environment(\.accentInk, settings.accent)
            .environment(\.lyricsInk, settings.lyricsInk)
            .tint(settings.accent)
    }
}
