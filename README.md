# Music Player – odtwarzacz muzyki z YouTube (iOS)

Aplikacja SwiftUI (iOS 17+, iPhone). Wygląd jak ekran tekstów w Apple Music (bez "Śpiewaj"),
z rozmytym, delikatnie poruszającym się tłem z okładki i szkłem "Liquid Glass". Cały interfejs jest po polsku.

## Co potrafi
- Wyszukiwanie w YouTube (YouTube Data API v3) i odtwarzanie natywne (YouTubeKit + AVPlayer), działa w tle i na zablokowanym ekranie.
- **Teksty zsynchronizowane linia po linii** (LRCLIB), kliknięcie linii = przewinięcie; korekta czasu
  tekstu (±0,5 s) w menu "•••".
- Playlisty: tworzenie, zmiana nazwy, kolejność, usuwanie. **Import playlisty lub pojedynczego filmu
  z linku YouTube** (`https://…`).
- Kolejka, shuffle, powtarzanie.
- Ustawienia: tło (kolorowy blur z okładki / czarne / białe) i przyciemnienie blurowanego tła. Szkło to zawsze
  Liquid Glass. Przewodnik "Jak korzystać z aplikacji" pokazuje się przy pierwszym uruchomieniu i jest w Ustawieniach.
- Sterowanie z iPhone'a: ekran blokady, słuchawki, AirPods, Centrum sterowania – play/pauza,
  następny/poprzedni,
  przewijanie suwakiem. Ekran blokady pokazuje zawsze przyciski następny/poprzedni. Głośność = systemowa.

## Jak zbudować .ipa (GitHub Actions) – wystarczy telefon
1. Wejdź na github.com → **New repository** (może być prywatne).
2. Wgraj **zawartość** tego projektu do repo (rozpakowany; `project.yml`, `Lumen/`, `Packages/` i `.github/`
   mają być w głównym katalogu repo). Na komputerze: `git init && git add . && git commit -m init && git push`.
   Na telefonie możesz też wgrać cały ZIP do głównego katalogu repo – workflow sam go rozpakuje,
   ale wtedy plik `.github/workflows/build-ipa.yml` dodaj ręcznie (Add file → Create new file).
4. Zakładka **Actions → Build iOS IPA → Run workflow**. Po ok. 5–10 min:
   - plik `MusicPlayer.ipa` jest w **Artifacts** (`MusicPlayer-ipa`) oraz w **Releases**.
5. (Opcjonalnie) **Settings → Secrets and variables → Actions → New secret** `YOUTUBE_API_KEY`
   – klucz zostanie wbudowany w aplikację. Możesz też wpisać go w aplikacji (Ustawienia).

Masz komputer? Możesz też wypakować ZIP-a, wypchnąć całość do repo (workflow jest w `.github/workflows/`).

## Instalacja .ipa na iPhonie
Plik z GitHuba jest **niepodpisany**. Trzeba go podpisać własnym Apple ID:
- **Sideloadly** lub **AltStore** (komputer Windows/Mac, darmowe Apple ID, odświeżanie co 7 dni), albo
- własny certyfikat Apple Developer + narzędzie do podpisywania.
Bez podpisu iOS go nie zainstaluje.

## Klucz YouTube Data API
Klucz jest wbudowany w aplikację (`YOUTUBE_API_KEY` w `project.yml`, można go nadpisać sekretem
`YOUTUBE_API_KEY` w GitHub Actions). W aplikacji nie ma już pola do zmiany klucza.
Limit: ok. 100 wyszukiwań dziennie (import playlisty kosztuje prawie nic).

## Ważne
- Odtwarzanie idzie **natywnie**: [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) (wbudowany w
  `Packages/YouTubeKit`) pobiera bezpośredni adres strumienia audio (AAC/m4a), a gra go `AVPlayer`.
  Nie ma już WebView ani osadzonego odtwarzacza YouTube, więc: brak reklam, brak błędów 152/153,
  brak zależności od osadzania, a muzyka gra w tle i na zablokowanym ekranie tak jak w zwykłym odtwarzaczu.
- Do wyszukiwania i importu playlist nadal używany jest YouTube Data API (klucz niżej).
- Tylko do użytku osobistego (sideload), niezgodne z regulaminem YouTube, więc nie nadaje się do App Store.
- Gdy piosenka nie startuje: Ustawienia → Odtwarzacz → **Odśwież strumień bieżącej piosenki**.
- Wydajność: tło animowane jest przez Core Animation (bez przeliczania co klatkę), a miniaturki są
  cache'owane. Jeśli nadal coś zwalnia, wybierz w Ustawieniach czarne lub białe tło.
- Kod nie został skompilowany w środowisku, w którym powstał (brak Xcode). Pierwszy build na GitHubie
  jest pierwszą kompilacją – jeśli się wysypie, w Artifacts jest `xcodebuild-log`; wklej błędy
  (linie z `error:`) a poprawię.

## Co nowego w 1.4.0
- **Piosenki zapisują się na stałe:** pierwsze odtworzenie leci ze strumienia, a w tle utwór jest pobierany do
  `Application Support/Lumen/Audio`. Następny utwór z kolejki jest pobierany z wyprzedzeniem. Każde kolejne
  odtworzenie startuje natychmiast i działa bez internetu. Teksty też zapisują się na stałe.
- **Teksty z dwóch źródeł naraz:** LRCLIB + NetEase, wybierana jest wersja o najbliższym czasie trwania do filmu
  (inna wersja = inne tempo). W menu „•••”: wybór innej wersji, tempo ±1% i czas ±0,5 s (osobno dla każdej piosenki).
- **Rozmycie tekstu** działa na całej długości tekstu (nie tylko blisko aktywnej linijki) i można je wyłączyć
  w Ustawieniach albo w menu „•••”.
- **Kolory:** tekstów i ikon, akcentu (menu, suwaki, przyciski) i tekstu piosenki.
- **Tło:** okładka (z rozmyciem lub bez), kolor / gradient, własne zdjęcie z galerii (z rozmyciem lub bez), czarne, białe.
- Usunięto przyciski „wyczyść pamięć” i „odśwież strumień”.

## Co nowego w 1.3.0
**Muzyka w tle (bez obejść):**
- `UIBackgroundModes: audio` + `AVAudioSession` `.playback` + `AVPlayer`: iOS sam pilnuje, żeby dźwięk grał.
- Adres następnej piosenki jest pobierany z wyprzedzeniem, więc przejście do kolejnej w tle jest natychmiastowe.
- Obsługa przerwań (telefon, budzik), odłączenia słuchawek i ekranu blokady (play/pauza/następny/poprzedni/przewijanie).
- Watchdog: jeśli adres strumienia wygaśnie albo zerwie się sieć, aplikacja sama pobiera nowy i wznawia od tego samego miejsca.

**Teksty zsynchronizowane z piosenką:**
- Zegar odtwarzacza tyka 10 razy na sekundę (wcześniej zdarzenia z YouTube przychodziły co 0,2–0,5 s).
- Usunięto sztuczne wyprzedzanie tekstu o 0,25 s.
- Uwzględniane jest opóźnienie wyjścia audio (Bluetooth ~0,2 s), przez które tekst wcześniej uciekał do przodu.
- Dobór tekstu mocniej premiuje wersję o takim samym czasie trwania jak film (inna wersja = rozjazd).
- Jeśli film ma np. intro, którego nie ma w wersji albumowej, popraw przesunięcie przyciskami przy tekście –
  zapamiętuje się osobno dla każdej piosenki.
