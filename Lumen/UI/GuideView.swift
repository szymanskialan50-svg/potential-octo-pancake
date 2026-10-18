import SwiftUI

/// Krótki przewodnik dla osób, które nigdy nie używały aplikacji.
struct GuideView: View {
    @Environment(\.ink) private var ink
    let onDone: () -> Void

    private struct Page: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(id: 0, icon: "music.note",
             title: "Witaj!",
             body: "Ta aplikacja odtwarza muzykę z YouTube. Wyszukujesz piosenkę, klikasz ją i gra. Możesz też tworzyć własne playlisty i czytać tekst piosenki podczas słuchania."),
        Page(id: 1, icon: "magnifyingglass",
             title: "1. Znajdź piosenkę",
             body: "Wejdź w zakładkę Szukaj na dole. Wpisz piosenkę lub wykonawcę i naciśnij Szukaj na klawiaturze. Kliknij piosenkę, żeby ją odtworzyć. Trzy kropki obok niej pozwalają zagrać ją jako następną, dodać do kolejki albo do playlisty."),
        Page(id: 2, icon: "music.note.list",
             title: "2. Playlisty",
             body: "Wejdź w zakładkę Biblioteka i kliknij przycisk +. Możesz utworzyć pustą playlistę albo wkleić link do playlisty lub filmu z YouTube, żeby ją zaimportować. Żeby dodać piosenkę do playlisty, kliknij trzy kropki obok niej i wybierz „Dodaj do playlisty”."),
        Page(id: 3, icon: "play.circle",
             title: "3. Odtwarzacz",
             body: "Gdy gra piosenka, na dole pojawia się mały pasek. Kliknij go, żeby otworzyć duży odtwarzacz: tekst, pasek postępu, przyciski poprzedni i następny, losowo, powtarzanie i kolejka. Kliknij linijkę tekstu, żeby przeskoczyć do tego momentu."),
        Page(id: 4, icon: "lock.iphone",
             title: "4. Muzyka w tle",
             body: "Możesz wyjść z aplikacji albo zablokować telefon, a muzyka będzie grać dalej. Pauzę, odtwarzanie i przewijanie znajdziesz na ekranie blokady lub w Centrum sterowania. Muzyka gra natywnie, tak jak w zwykłym odtwarzaczu, więc nie trzeba nic robić."),
        Page(id: 5, icon: "gearshape",
             title: "5. Ustawienia i problemy",
             body: "W Ustawieniach wybierasz tło (okładka piosenki, własny kolor lub gradient, własne zdjęcie, czarne albo białe), włączasz lub wyłączasz rozmycie i zmieniasz kolory tekstów, menu i tekstu piosenki. Jeśli jakaś piosenka się nie włącza, sprawdź internet i spróbuj ponownie. Filmy prywatne, usunięte lub z ograniczeniem wiekowym są pomijane.")
    ]

    @State private var index = 0

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $index) {
                ForEach(pages) { page in
                    pageView(page).tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .padding(.top, 12)

            Button {
                if index < pages.count - 1 {
                    withAnimation { index += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(index < pages.count - 1 ? "Dalej" : "Zaczynamy!")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(ink.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            Button("Pomiń") { onDone() }
                .font(.system(size: 15))
                .foregroundStyle(ink.opacity(0.6))
                .frame(minHeight: 44)
                .padding(.bottom, 8)
        }
        .background(ink.opacity(0.04).ignoresSafeArea())
        .interactiveDismissDisabled(false)
    }

    private func pageView(_ p: Page) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: p.icon)
                    .font(.system(size: 64, weight: .semibold))
                    .padding(.top, 30)
                Text(p.title)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(p.body)
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 50)
        }
    }
}
