import SwiftUI

/// Small in-memory cache so list thumbnails do not reload (and lag) while scrolling.
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSURL, UIImage>()

    init() { cache.countLimit = 500 }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let full = UIImage(data: data) else { return nil }
        let small = ArtworkLoader.downscale(full, maxSide: 180)
        cache.setObject(small, forKey: url as NSURL)
        return small
    }
}

struct TrackThumb: View {
    @Environment(\.ink) private var ink
    let track: Track
    var size: CGFloat = 52
    @State private var image: UIImage?

    init(track: Track, size: CGFloat = 52) {
        self.track = track
        self.size = size
        _image = State(initialValue: track.artworkURL.flatMap { ThumbCache.shared.image(for: $0) })
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ink.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(ink.opacity(0.5)))
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: track.id) {
            guard let url = track.artworkURL else { image = nil; return }
            if let hit = ThumbCache.shared.image(for: url) { image = hit; return }
            image = nil
            image = await ThumbCache.shared.load(url)
        }
    }
}

struct TrackRow: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    let track: Track
    var isCurrent: Bool = false
    let onPlay: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil

    private var subtitle: String {
        track.duration > 0 ? "\(track.artist) · \(Fmt.time(track.duration))" : track.artist
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    TrackThumb(track: track)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ink)
                            }
                            Text(track.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(ink)
                                .lineLimit(1)
                        }
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(ink.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { engine.enqueueNext(track) } label: { Label("Odtwórz jako następną", systemImage: "text.insert") }
                Button { engine.enqueueLast(track) } label: { Label("Dodaj do kolejki", systemImage: "text.append") }
                if let add = onAddToPlaylist {
                    Button(action: add) { Label("Dodaj do playlisty…", systemImage: "plus") }
                }
                Link(destination: track.watchURL) { Label("Otwórz w YouTube", systemImage: "arrow.up.right.square") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ink.opacity(0.8))
                    .frame(width: 48, height: 56)
                    .contentShape(Rectangle())
            }
        }
    }
}

struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Nowa playlista") {
                    HStack {
                        TextField("Nazwa playlisty", text: $newName)
                        Button("Utwórz") {
                            let p = library.create(name: newName, tracks: tracks)
                            toast.show("Dodano do \(p.name)")
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Twoje playlisty") {
                    if library.playlists.isEmpty {
                        Text("Brak playlist").foregroundStyle(.secondary)
                    }
                    ForEach(library.playlists) { p in
                        Button {
                            let n = library.add(tracks, to: p.id)
                            toast.show(n > 0 ? "Dodano do \(p.name)" : "Już jest w \(p.name)")
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text("\(p.tracks.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dodaj do playlisty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct EmptyHint: View {
    @Environment(\.ink) private var ink
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
            Text(message).font(.system(size: 14)).multilineTextAlignment(.center)
                .foregroundStyle(ink.opacity(0.65))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
