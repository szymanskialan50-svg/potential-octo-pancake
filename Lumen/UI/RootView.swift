import SwiftUI

enum AppTab: Hashable { case library, search, settings }

extension View {
    func pageVisible(_ visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(.easeInOut(duration: 0.16), value: visible)
    }
}

struct RootView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var volume: VolumeController
    @State private var tab: AppTab = .library
    @State private var showNowPlaying = false
    @State private var showGuide = false
    @State private var librarySelected: UUID? = nil
    @StateObject private var searchModel = SearchModel()

    var body: some View {
        ZStack {
            AnimatedBackground(isActive: !showNowPlaying)
            pages
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            HiddenVolumeView(controller: volume)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .onAppear {
            if !settings.data.guideSeen { showGuide = true }
        }
        .sheet(isPresented: $showGuide, onDismiss: { settings.data.guideSeen = true }) {
            GuideView { showGuide = false }
                .preferredColorScheme(settings.colorScheme)
        }
        .overlay(alignment: .top) { toastView }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast.message)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(toast)
                .environmentObject(volume)
                .preferredColorScheme(settings.colorScheme)
                .tint(accentInk)
        }
    }

    /// All three pages stay alive and only the active one is visible and touchable.
    /// (Rebuilding a page on every tab switch was what made switching tabs lag.)
    private var pages: some View {
        ZStack {
            LibraryRootView(selected: $librarySelected)
                .pageVisible(tab == .library)
            SearchView(model: searchModel)
                .pageVisible(tab == .search)
            SettingsView()
                .pageVisible(tab == .settings)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if engine.currentTrack != nil {
                MiniPlayerBar { showNowPlaying = true }
            }
            tabBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var tabBar: some View {
        LiquidTabBar(selection: $tab)
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = toast.message {
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glass(Capsule())
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct MiniPlayerBar: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    let open: () -> Void

    var body: some View {
        if let t = engine.currentTrack {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkView(size: 44, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                        Text(t.artist).font(.system(size: 12)).foregroundStyle(ink.opacity(0.65)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.wantsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { engine.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

struct ArtworkView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let img = engine.artwork {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let t = engine.currentTrack {
                TrackThumb(track: t, size: size)
            } else {
                Rectangle().fill(ink.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
