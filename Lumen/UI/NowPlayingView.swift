import SwiftUI

struct BarSlider: View {
    @Environment(\.accentInk) private var accentInk
    @Environment(\.ink) private var ink
    let value: Double   // 0...1
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void = { _ in }
    @State private var dragging = false

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.25))
                Capsule().fill(accentInk.opacity(0.92))
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
            .frame(height: dragging ? 12 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        onChanged(fraction(g.location.x, geo.size.width))
                    }
                    .onEnded { g in
                        dragging = false
                        onEnded(fraction(g.location.x, geo.size.width))
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
    }
}

struct ProgressSection: View {
    @Environment(\.ink) private var ink
    @ObservedObject var clock: PlaybackClock
    let seek: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        let duration = max(clock.duration, 0.01)
        let shown = dragging ? dragValue : min(clock.time, duration)
        VStack(spacing: 2) {
            BarSlider(value: shown / duration, onChanged: { f in
                dragging = true
                dragValue = f * duration
            }, onEnded: { f in
                seek(f * duration)
                dragging = false
            })
            HStack {
                Text(Fmt.time(shown))
                Spacer()
                Text("-" + Fmt.time(max(duration - shown, 0)))
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(ink.opacity(0.6))
        }
    }
}

struct VolumeRow: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var volume: VolumeController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 12)).foregroundStyle(ink.opacity(0.7))
            BarSlider(value: Double(volume.level), onChanged: { f in volume.set(Float(f)) })
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundStyle(ink.opacity(0.7))
        }
    }
}

struct NowPlayingView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @EnvironmentObject var volume: VolumeController
    @State private var showLyrics = true
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var showLyricsPicker = false

    var body: some View {
        ZStack {
            AnimatedBackground()
            VStack(spacing: 0) {
                Capsule()
                    .fill(ink.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                if showLyrics {
                    header
                    LyricsView(lyrics: engine.lyrics)
                        .padding(.top, 6)
                } else {
                    bigArtwork
                }

                ProgressSection(clock: engine.clock, seek: { engine.seek(to: $0) })
                    .padding(.top, 6)
                controls
                VolumeRow().padding(.bottom, 14)
                bottomRow
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showLyricsPicker) {
            LyricsPickerSheet()
                .environmentObject(engine)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(tracks: engine.currentTrack.map { [$0] } ?? [])
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(size: 72, radius: 12)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            titleBlock
            Spacer(minLength: 8)
            moreMenu
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.currentTrack?.title ?? "Nic nie gra")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(2)
            Text(engine.currentTrack?.artist ?? "")
                .font(.system(size: 18))
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var bigArtwork: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ArtworkView(size: 310, radius: 22)
                .scaleEffect(engine.isPlaying ? 1 : 0.86)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: engine.isPlaying)
            HStack {
                titleBlock
                Spacer(minLength: 8)
                moreMenu
            }
            Spacer(minLength: 0)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { showAddToPlaylist = true } label: { Label("Dodaj do playlisty…", systemImage: "plus") }
            Button { engine.adjustLyricsOffset(by: 0.5) } label: { Label("Tekst wcześniej (+0,5 s)", systemImage: "arrow.up.to.line") }
            Button { engine.adjustLyricsOffset(by: -0.5) } label: { Label("Tekst później (−0,5 s)", systemImage: "arrow.down.to.line") }
            Button { engine.adjustLyricsTempo(byPercent: 1) } label: { Label("Tekst wolniejszy (+1%)", systemImage: "tortoise") }
            Button { engine.adjustLyricsTempo(byPercent: -1) } label: { Label("Tekst szybszy (−1%)", systemImage: "hare") }
            Button { engine.resetLyricsOffset() } label: { Label("Resetuj czas i tempo tekstu", systemImage: "arrow.counterclockwise") }
            Button { showLyricsPicker = true } label: { Label("Wybierz inną wersję tekstu…", systemImage: "text.quote") }
            Toggle(isOn: $settings.data.blurInactiveLyrics) { Label("Rozmywaj nieaktywne linijki", systemImage: "drop") }
            Button { engine.skip(by: -10) } label: { Label("Cofnij 10 s", systemImage: "gobackward.10") }
            Button { engine.skip(by: 10) } label: { Label("Do przodu 10 s", systemImage: "goforward.10") }
            if let t = engine.currentTrack {
                Link(destination: t.watchURL) { Label("Otwórz w YouTube", systemImage: "arrow.up.right.square") }
                ShareLink(item: t.watchURL) { Label("Udostępnij", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 48, height: 48)
                .glass(Circle(), interactive: true)
                .contentShape(Circle())
        }
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(ink)
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button { engine.togglePlayPause() } label: {
                ZStack {
                    if engine.wantsPlaying && engine.isBuffering && !engine.isPlaying {
                        ProgressView().tint(accentInk).scaleEffect(1.4)
                    } else {
                        Image(systemName: engine.wantsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 50)).foregroundStyle(ink)
                    }
                }
                .frame(width: 80, height: 80)
                .contentShape(Rectangle())
            }
            Spacer()
            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(ink)
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var bottomRow: some View {
        HStack {
            Button { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
                    .overlay(Circle().stroke(accentInk.opacity(showLyrics ? 0.8 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Spacer()
            AirPlayButton(color: ink)
                .frame(width: 52, height: 52)
                .glass(Circle(), interactive: true)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Queue

struct QueueSheet: View {
    @Environment(\.accentInk) private var accentInk
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Button { engine.toggleShuffle() } label: {
                            Label("Losowo", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .tint(engine.shuffle ? accentInk : Color.gray)
                        Button { engine.cycleRepeat() } label: {
                            Label(repeatTitle, systemImage: engine.repeatMode == .one ? "repeat.1" : "repeat")
                        }
                        .buttonStyle(.bordered)
                        .tint(engine.repeatMode == .off ? Color.gray : accentInk)
                    }
                }
                Section("Następne") {
                    ForEach(Array(engine.queue.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track, isCurrent: index == engine.currentIndex, onPlay: { engine.jump(to: index) })
                    }
                    .onDelete { engine.removeFromQueue(at: $0) }
                }
            }
            .navigationTitle("Kolejka")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var repeatTitle: String {
        switch engine.repeatMode {
        case .off: return "Powtarzaj"
        case .all: return "Powtarzaj wszystko"
        case .one: return "Powtarzaj jedną"
        }
    }
}
