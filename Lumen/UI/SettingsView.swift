import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter
    @State private var showGuide = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var stored: (count: Int, bytes: Int64) = (0, 0)

    private var rowBackground: Color { ink.opacity(0.09) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Ustawienia")
            Form {
                helpSection
                backgroundSection
                colorsSection
                lyricsSection
                storageSection
            }
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showGuide) {
            GuideView { showGuide = false }
                .preferredColorScheme(settings.colorScheme)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    settings.setBackgroundImage(data)
                } else {
                    toast.show("Nie udało się wczytać zdjęcia")
                }
                pickerItem = nil
            }
        }
        .task { stored = await AudioCache.shared.stats() }
    }

    // MARK: Sections

    private var helpSection: some View {
        Section {
            Button {
                showGuide = true
            } label: {
                Label("Jak korzystać z aplikacji", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
        } footer: {
            Text("Krótki przewodnik krok po kroku dla początkujących.")
        }
        .listRowBackground(rowBackground)
    }

    private var backgroundSection: some View {
        Section {
            Picker("Tło aplikacji", selection: $settings.data.theme) {
                ForEach(ThemeMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.menu)

            switch settings.data.theme {
            case .blur:
                Toggle("Rozmycie okładki", isOn: $settings.data.artworkBlur)
                dimSlider
            case .color:
                Toggle("Gradient", isOn: $settings.data.backgroundGradient)
                ColorPicker(settings.data.backgroundGradient ? "Kolor na górze" : "Kolor tła",
                            selection: colorBinding(\.backgroundColorHex, fallback: Color(hex: "2B2B6B")),
                            supportsOpacity: false)
                if settings.data.backgroundGradient {
                    ColorPicker("Kolor na dole",
                                selection: colorBinding(\.backgroundColor2Hex, fallback: Color(hex: "07070F")),
                                supportsOpacity: false)
                }
            case .image:
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(settings.backgroundImage == nil ? "Wybierz zdjęcie z galerii" : "Zmień zdjęcie",
                          systemImage: "photo")
                }
                if settings.backgroundImage != nil {
                    Toggle("Rozmycie zdjęcia", isOn: $settings.data.imageBlur)
                    if settings.data.imageBlur {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Siła rozmycia").font(.subheadline)
                            Slider(value: $settings.data.imageBlurRadius, in: 2...50)
                        }
                    }
                    dimSlider
                    Button("Usuń zdjęcie", role: .destructive) { settings.removeBackgroundImage() }
                }
            case .black, .white:
                EmptyView()
            }
        } header: {
            Text("Tło")
        } footer: {
            Text(backgroundFooter)
        }
        .listRowBackground(rowBackground)
    }

    private var backgroundFooter: String {
        switch settings.data.theme {
        case .blur: return "Kolorowe tło z okładki grającej piosenki, bardzo powoli się porusza. Wyłącz rozmycie, żeby widzieć ostrą okładkę."
        case .color: return "Jednolity kolor albo gradient w wybranych kolorach."
        case .image: return "Własne zdjęcie z galerii, z rozmyciem lub bez."
        case .black: return "Czarne tło."
        case .white: return "Białe tło (cały interfejs przełącza się na jasny)."
        }
    }

    private var dimSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Przyciemnienie").font(.subheadline)
            Slider(value: $settings.data.dim, in: 0...0.8)
        }
    }

    private var colorsSection: some View {
        Section {
            ColorPicker("Kolor tekstów i ikon", selection: colorBinding(\.inkHex, fallback: Color.primary),
                        supportsOpacity: false)
            ColorPicker("Kolor akcentu (menu, suwaki, przyciski)", selection: colorBinding(\.accentHex, fallback: Color.primary),
                        supportsOpacity: false)
            ColorPicker("Kolor tekstu piosenki", selection: colorBinding(\.lyricsHex, fallback: Color.primary),
                        supportsOpacity: false)
            Button("Przywróć kolory domyślne") { settings.resetColors() }
        } header: {
            Text("Kolory")
        } footer: {
            Text("Domyślnie kolory są automatyczne: biały na ciemnym tle, czarny na jasnym.")
        }
        .listRowBackground(rowBackground)
    }

    private var lyricsSection: some View {
        Section {
            Toggle("Rozmywaj nieaktywne linijki", isOn: $settings.data.blurInactiveLyrics)
        } header: {
            Text("Teksty piosenek")
        } footer: {
            Text("Rozmycie rośnie z odległością od aktualnej linijki. Teksty pochodzą z LRCLIB i NetEase (wybierana jest wersja o takim samym czasie trwania), a po pierwszym pobraniu są zapisane na stałe. Wersję, tempo i czas tekstu zmienisz w menu „•••” w odtwarzaczu.")
        }
        .listRowBackground(rowBackground)
    }

    private var storageSection: some View {
        Section {
            HStack {
                Text("Zapisane piosenki")
                Spacer()
                Text("\(stored.count) · \(ByteCountFormatter.string(fromByteCount: stored.bytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pamięć")
        } footer: {
            Text("Każda odtworzona piosenka jest pobierana raz i zostaje w telefonie, więc następnym razem startuje od razu i działa bez internetu.")
        }
        .listRowBackground(rowBackground)
    }

    // MARK: Helpers

    private func colorBinding(_ key: WritableKeyPath<SettingsData, String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: {
                let hex = settings.data[keyPath: key]
                return hex.isEmpty ? fallback : Color(hex: hex)
            },
            set: { settings.data[keyPath: key] = $0.hexString }
        )
    }
}
