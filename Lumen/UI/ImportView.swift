import SwiftUI
import UIKit

struct ImportView: View {
    var initialText: String = ""
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case idle
        case loading
        case ready(tracks: [Track], skipped: Int)
        case failed(String)
    }

    @State private var text = ""
    @State private var name = ""
    @State private var phase: Phase = .idle
    @State private var batch: TrackBatch? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("Link do playlisty lub filmu z YouTube") {
                    TextField("https://www.youtube.com/playlist?list=…", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    HStack {
                        Button("Wklej") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                        Spacer()
                        Button("Pobierz") { fetch() }
                            .buttonStyle(.bordered)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                switch phase {
                case .idle:
                    EmptyView()
                case .loading:
                    Section { HStack { ProgressView(); Text("Pobieranie z YouTube…").padding(.leading, 8) } }
                case .failed(let message):
                    Section { Text(message).foregroundStyle(.red) }
                case .ready(let tracks, let skipped):
                    readySection(tracks: tracks, skipped: skipped)
                }
            }
            .navigationTitle("Import z YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Zamknij") { dismiss() } }
            }
            .onAppear {
                if text.isEmpty && !initialText.isEmpty {
                    text = initialText
                    fetch()
                }
            }
            .sheet(item: $batch) { b in
                AddToPlaylistSheet(tracks: b.tracks)
                    .environmentObject(library)
                    .environmentObject(toast)
                    .preferredColorScheme(settings.colorScheme)
            }
        }
    }

    @ViewBuilder
    private func readySection(tracks: [Track], skipped: Int) -> some View {
        if tracks.count > 1 {
            Section("Playlista") {
                TextField("Nazwa playlisty", text: $name)
                Text(Pl.songs(tracks.count) + (skipped > 0 ? " · pominięto: \(skipped) (prywatne lub usunięte)" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Zapisz jako playlistę") {
                    let p = library.create(name: name, tracks: tracks)
                    toast.show("Zaimportowano \"\(p.name)\" (\(Pl.songs(p.tracks.count)))")
                    dismiss()
                }
                Button("Odtwórz teraz") {
                    engine.play(tracks, startAt: 0)
                    dismiss()
                }
            }
        } else if let t = tracks.first {
            Section("Piosenka") {
                HStack(spacing: 12) {
                    TrackThumb(track: t, size: 52)
                    VStack(alignment: .leading) {
                        Text(t.title).lineLimit(2)
                        Text(t.artist).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Dodaj do playlisty…") { batch = TrackBatch(tracks: [t]) }
                Button("Odtwórz teraz") {
                    engine.playNow(t)
                    dismiss()
                }
            }
        }
        Section("Podgląd") {
            ForEach(Array(tracks.prefix(8).enumerated()), id: \.offset) { _, t in
                HStack(spacing: 10) {
                    TrackThumb(track: t, size: 38)
                    Text(t.title).font(.subheadline).lineLimit(1)
                }
            }
            if tracks.count > 8 {
                Text("+ \(tracks.count - 8) więcej").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func fetch() {
        guard let link = YouTubeURL.parse(text, allowBareID: true) else {
            phase = .failed("To nie wygląda na link do filmu lub playlisty z YouTube.")
            return
        }
        var playlistID: String? = nil
        var videoID: String? = nil
        switch link {
        case .video(let v):
            videoID = v
        case .playlist(let p):
            playlistID = p
        case .videoInPlaylist(let v, let p):
            // "Mix" playlists (RD…) are generated by YouTube and cannot be read through the API
            if p.hasPrefix("RD") { videoID = v } else { playlistID = p }
        }
        phase = .loading
        let api = settings.api
        Task {
            do {
                if let pid = playlistID {
                    let r = try await api.playlist(id: pid)
                    name = r.title
                    phase = .ready(tracks: r.tracks, skipped: r.skipped)
                } else if let vid = videoID {
                    let t = try await api.video(id: vid)
                    name = t.title
                    phase = .ready(tracks: [t], skipped: 0)
                }
            } catch let err {
                phase = .failed(err.localizedDescription)
            }
        }
    }
}
