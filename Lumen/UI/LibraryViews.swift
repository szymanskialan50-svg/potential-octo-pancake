import SwiftUI

struct TrackBatch: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

struct ScreenHeader<Trailing: View>: View {
    @Environment(\.ink) private var ink
    let title: String
    let back: (() -> Void)?
    let trailing: Trailing

    init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.back = back
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let back = back {
                GlassIconButton(systemName: "chevron.left", size: 40, action: back)
            }
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String, back: (() -> Void)? = nil) {
        self.init(title, back: back) { EmptyView() }
    }
}

// MARK: - Library root

struct LibraryRootView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @Binding var selected: UUID?
    @State private var showImport = false
    @State private var showNew = false
    @State private var newName = ""
    @State private var renameTarget: UUID? = nil
    @State private var renameName = ""
    @State private var showRename = false

    var body: some View {
        ZStack {
            if let id = selected {
                PlaylistDetailView(playlistID: id) {
                    withAnimation(.easeInOut(duration: 0.25)) { selected = nil }
                }
                .transition(.move(edge: .trailing))
            } else {
                home.transition(.opacity)
            }
        }
        .sheet(isPresented: $showImport) {
            ImportView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .alert("Nowa playlista", isPresented: $showNew) {
            TextField("Nazwa", text: $newName)
            Button("Utwórz") {
                library.create(name: newName)
                newName = ""
            }
            Button("Anuluj", role: .cancel) { newName = "" }
        }
        .alert("Zmień nazwę playlisty", isPresented: $showRename) {
            TextField("Nazwa", text: $renameName)
            Button("Zapisz") {
                if let id = renameTarget { library.rename(id, to: renameName) }
            }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            ScreenHeader("Biblioteka") {
                Menu {
                    Button { showNew = true } label: { Label("Nowa playlista", systemImage: "plus") }
                    Button { showImport = true } label: { Label("Importuj z YouTube", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 48, height: 48)
                        .glass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
            }
            if library.playlists.isEmpty {
                ScrollView {
                    EmptyHint(icon: "music.note.list", title: "Brak playlist",
                              message: "Kliknij +, aby utworzyć playlistę albo zaimportować ją z linku do playlisty YouTube.")
                        .padding(.top, 60)
                }
            } else {
                List {
                    ForEach(library.playlists) { p in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { selected = p.id }
                        } label: {
                            PlaylistRow(playlist: p)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button {
                                renameTarget = p.id
                                renameName = p.name
                                showRename = true
                            } label: { Label("Zmień nazwę", systemImage: "pencil") }
                            Button(role: .destructive) { library.delete(id: p.id) } label: { Label("Usuń", systemImage: "trash") }
                        }
                    }
                    .onDelete { library.delete(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct PlaylistRow: View {
    @Environment(\.ink) private var ink
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            if let first = playlist.tracks.first {
                TrackThumb(track: first, size: 62)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ink.opacity(0.12))
                    .frame(width: 62, height: 62)
                    .overlay(Image(systemName: "music.note.list").foregroundStyle(ink.opacity(0.6)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Text("\(Pl.songs(playlist.tracks.count))").font(.system(size: 14)).foregroundStyle(ink.opacity(0.6))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.4))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @Environment(\.ink) private var ink
    let playlistID: UUID
    let back: () -> Void
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @State private var editMode: EditMode = .inactive
    @State private var batch: TrackBatch? = nil

    var body: some View {
        if let p = library.playlist(playlistID) {
            content(p)
        } else {
            Color.clear.onAppear(perform: back)
        }
    }

    private func content(_ p: Playlist) -> some View {
        VStack(spacing: 0) {
            ScreenHeader(p.name, back: back) {
                Button(editMode.isEditing ? "Gotowe" : "Edytuj") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
            }
            HStack(spacing: 12) {
                actionButton("Odtwórz", "play.fill") { engine.play(p.tracks, startAt: 0) }
                actionButton("Losowo", "shuffle") { engine.play(p.tracks, startAt: 0, shuffled: true) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .opacity(p.tracks.isEmpty ? 0.4 : 1)
            .disabled(p.tracks.isEmpty)

            if p.tracks.isEmpty {
                ScrollView {
                    EmptyHint(icon: "music.note", title: "Pusta playlista",
                              message: "Użyj zakładki Szukaj i menu ••• przy piosence, aby dodać ją tutaj.")
                        .padding(.top, 40)
                }
            } else {
                List {
                    ForEach(Array(p.tracks.enumerated()), id: \.element.id) { index, t in
                        TrackRow(track: t,
                                 isCurrent: engine.currentTrack?.id == t.id,
                                 onPlay: { engine.play(p.tracks, startAt: index) },
                                 onAddToPlaylist: { batch = TrackBatch(tracks: [t]) })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onDelete { library.remove(at: $0, from: p.id) }
                    .onMove { library.move(from: $0, to: $1, in: p.id) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
        .sheet(item: $batch) { b in
            AddToPlaylistSheet(tracks: b.tracks)
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private func actionButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .glass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}
