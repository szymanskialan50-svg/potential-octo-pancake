import SwiftUI

/// Apple Music style synced lyrics: big bold lines, active line sharp, others dimmed and blurred.
struct LyricsView: View {
    @Environment(\.lyricsInk) private var lyricsInk
    @ObservedObject var lyrics: LyricsController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine

    private let anchor = UnitPoint(x: 0, y: 0.22)

    var body: some View {
        switch lyrics.phase {
        case .synced:
            synced.id(engine.currentTrack?.id ?? "none")
        case .plain:
            ScrollView(showsIndicators: false) {
                Text(lyrics.plainText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(lyricsInk.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                Spacer().frame(height: 30)
            }
        case .idle, .loading:
            VStack { Spacer(); ProgressView().tint(lyricsInk); Spacer() }
                .frame(maxWidth: .infinity)
        case .instrumental:
            message("Utwór instrumentalny", "music.note")
        case .notFound:
            message("Nie znaleziono tekstu", "text.quote")
        }
    }

    private func message(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 34, weight: .semibold))
            Text(text).font(.system(size: 22, weight: .bold))
            Spacer()
        }
        .foregroundStyle(lyricsInk.opacity(0.7))
        .frame(maxWidth: .infinity)
    }

    private var synced: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Spacer().frame(height: 30)
                    ForEach(lyrics.lines) { line in
                        LyricLineView(text: line.text,
                                      distance: abs(line.id - lyrics.activeIndex),
                                      isActive: line.id == lyrics.activeIndex,
                                      fontSize: 34,
                                      blurOn: settings.data.blurInactiveLyrics) {
                            engine.seek(to: max(0, line.time - lyrics.offset))
                        }
                        .id(line.id)
                    }
                    Spacer().frame(height: 280)
                }
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: lyrics.activeIndex) { _, newIndex in
                guard newIndex >= 0 else { return }
                withAnimation(.spring(response: 0.65, dampingFraction: 0.88)) {
                    proxy.scrollTo(newIndex, anchor: anchor)
                }
            }
            .onAppear {
                if lyrics.activeIndex >= 0 { proxy.scrollTo(lyrics.activeIndex, anchor: anchor) }
            }
        }
    }
}

struct LyricLineView: View {
    @Environment(\.lyricsInk) private var lyricsInk
    let text: String
    let distance: Int
    let isActive: Bool
    let fontSize: Double
    let blurOn: Bool
    let onTap: () -> Void

    var body: some View {
        Text(text.isEmpty ? "• • •" : text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(lyricsInk)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isActive ? 1 : (distance > 5 ? 0.28 : 0.4))
            // Rozmycie rośnie z odległością od aktywnej linijki i zostaje takie samo aż do końca tekstu,
            // więc przewijając nie widać "ostrych" linijek daleko od tej, która aktualnie leci.
            .blur(radius: (blurOn && !isActive) ? CGFloat(min(distance, 4)) * 1.5 : 0)
            .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
            .animation(distance <= 6 ? .easeInOut(duration: 0.35) : nil, value: isActive)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

// MARK: - Picker of another lyrics version

struct LyricsPickerSheet: View {
    @EnvironmentObject var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LyricsCandidate] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Wykonawca i tytuł", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await run() } }
                } footer: {
                    Text("Wybierz wersję o takim samym czasie trwania jak piosenka (zielony czas). Inna wersja = inny rytm tekstu.")
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results, id: \.uid) { c in
                    Button {
                        engine.chooseLyrics(c)
                        dismiss()
                    } label: { row(c) }
                }
            }
            .navigationTitle("Wersja tekstu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } } }
            .task {
                if let t = engine.currentTrack, let g = TitleCleaner.guesses(title: t.title, channel: t.artist).first {
                    query = "\(g.artist) \(g.title)"
                }
                await run()
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ c: LyricsCandidate) -> some View {
        let video = engine.currentTrack?.duration ?? 0
        let isCurrent = engine.lyrics.current?.uid == c.uid
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title.isEmpty ? "—" : c.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Text(c.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(c.source ?? "")
                    if let d = c.duration, d > 0 {
                        Text("· \(Fmt.time(d))" + (video > 0 ? " (film \(Fmt.time(video)))" : ""))
                            .foregroundStyle(video > 0 && abs(d - video) <= 2 ? Color.green : Color.orange)
                    }
                    Text(c.hasSynced ? "· z synchronizacją" : "· zwykły tekst")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isCurrent { Image(systemName: "checkmark.circle.fill") }
        }
        .contentShape(Rectangle())
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        let list = await LyricsService.shared.search(query: q)
        let video = engine.currentTrack?.duration ?? 0
        // Z synchronizacją i najbliższym czasem trwania na górze.
        results = list.sorted {
            if $0.hasSynced != $1.hasSynced { return $0.hasSynced }
            guard video > 0 else { return false }
            return abs(($0.duration ?? 9999) - video) < abs(($1.duration ?? 9999) - video)
        }
        loading = false
    }
}
