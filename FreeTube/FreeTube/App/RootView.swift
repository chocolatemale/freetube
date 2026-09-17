import SwiftUI
import LNPopupUI
import Kingfisher
import UIKit

/// Top-level tabbed shell. CLAUDE.md §8: mini-player sits above the tab bar and persists across tabs.
///
/// Tab layout (5 visible):
/// - Feed (latest cached videos from local subscriptions; optional)
/// - Search (search field, suggestions, results, and local recent searches)
/// - Music (YouTube Music home / explore / library, audio-only playback; optional)
/// - Library (subsumes the former Account + Subscriptions tabs; includes Favorites/Recents/Playlists/Login)
/// - Downloads (saved videos, transfer queue, and yt-dlp link downloads)
///
/// Settings is a sheet (gear button in Library, ⌘, on Mac) rather than a sixth tab: iPhone folds
/// anything past five tabs into a "More" list, which is worse than one extra tap for a screen
/// nobody visits daily.
@available(iOS 17.0, *)
struct RootView: View {
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = DebugLaunchOptions.initialTab ?? .feed
    @State private var searchActivation = 0
    @AppStorage("showSubscriptionFeedTab") private var showSubscriptionFeedTab = true
    @AppStorage("showMusicTab") private var showMusicTab = true
    @State private var showingSettings = false
    @State private var feedNavigationRequest: AppNavigationRequest?
    @State private var searchNavigationRequest: AppNavigationRequest?
    @State private var musicNavigationRequest: AppNavigationRequest?
    @State private var libraryNavigationRequest: AppNavigationRequest?
    @State private var downloadsNavigationRequest: AppNavigationRequest?
    /// Direct observation of the shared download manager — no AsyncStream subscription needed since
    /// `DownloadManager` is itself `@Observable`. Both this view (for the badge) and `DownloadsScreen`
    /// (for the list) read the same source of truth.
    @State private var downloads = DownloadManager.shared
    /// Cached thumbnail for the current video so the mini-player bar shows the actual preview instead
    /// of a placeholder icon. Loaded via Kingfisher's cache when `currentVideo` changes.
    @State private var thumbnail: UIImage?
    /// Retained target for the UIKit swipe recognizers installed on LNPopupUI's native bar.
    @State private var popupBarDismissGesture = PopupBarDismissGestureHandler()

    enum Tab: String, Hashable {
        case feed, search, music, library, downloads
        /// Not a tab bar item — selecting it (Mac menu / ⌘,) presents the Settings sheet.
        case settings
    }

    private var activeDownloadsCount: Int {
        downloads.activeTasks.filter { snapshot in
            switch snapshot.state {
            case .queued, .downloading, .paused: return true
            case .completed, .failed: return false
            }
        }.count
    }

    var body: some View {
        @Bindable var player = player

        tabShell
        .popup(
            isBarPresented: $player.miniPlayerVisible,
            isPopupOpen: $player.fullScreenPresented
        ) {
            // The popup's content closure is called once and its result is hosted; SwiftUI does NOT
            // re-evaluate the closure on every parent body re-render. So any modifier that takes a
            // captured value (like `.popupProgress(value)`) freezes at the closure-creation time.
            // To get live progress updates we wrap the modifiers in `PopupContentWrapper`, which is
            // itself a `View` observing the player — when `player.elapsed` changes, the wrapper's
            // body re-renders and `.popupProgress(...)` re-applies with the new value.
            PopupContentWrapper(thumbnail: thumbnail)
        }
        .popupInteractionStyle(player.chapterListPresented
            || !player.playerPanelAtTop
            || player.playerPanelGestureStartedAwayFromTop
            ? UIViewController.PopupInteractionStyle.none
            : UIViewController.PopupInteractionStyle.drag)
        .popupCloseButtonStyle(LNPopupCloseButton.Style.none)
        .popupBarStyle(LNPopupBar.Style.prominent)
        // LNPopupController's marquee animation corrupts the native title/subtitle layout on
        // iOS 26. Static native labels are the last known-good configuration: they truncate long
        // text but remain vertically centred and never animate out of the bar.
        .popupBarMarqueeScrollEnabled(false)
        // Explicitly enable the thin progress line at the bottom of the popup bar so playback
        // and download progress are always visible without expanding the player.
        .popupBarProgressViewStyle(.bottom)
        .popupBarCustomizer { popupBar in
            popupBarDismissGesture.install(on: popupBar) {
                player.dismiss()
            }
        }
        .overlay(alignment: .top) {
            if let notice = player.queueNotice {
                Label {
                    Text("Playing next: \(notice.title)")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "text.insert")
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 300)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                .padding(.top, 8)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: player.queueNotice?.id)
        .task {
            await SessionManager.shared.bootstrap()
            if let videoID = DebugLaunchOptions.playVideoID {
                player.load(Video(
                    id: videoID, title: "YouTube video", channelID: "", channelName: "",
                    channelThumbnailURL: nil, thumbnailURL: nil, duration: nil, viewCount: nil,
                    publishedAt: nil, descriptionSnippet: nil, isLive: false, isShort: false
                ))
            }
        }
        // Refresh the cached thumbnail whenever the user picks a new video. The mini-player's
        // `PopupContentWrapper` reads this so the bar shows the actual preview.
        .onChange(of: player.currentVideo?.id, initial: true) {
            loadThumbnailForCurrentVideo()
        }
        // Force a light-content status bar (white glyphs) while the full-screen player is up.
        // SwiftUI's `.preferredColorScheme(.dark)` on the popup content doesn't propagate through
        // LNPopupUI's hosting chain to UIKit's status-bar style, but flipping the window's
        // `overrideUserInterfaceStyle = .dark` does — UIKit recomputes the status bar trait from
        // that, gets `.dark`, and switches the bar to light content. We restore `.unspecified` when
        // the popup collapses so the rest of the app honors the system appearance again.
        .onChange(of: player.fullScreenPresented) { _, presented in
            updateStatusBarOverride(forFullScreenOpen: presented)
            if presented {
                player.requestInlinePlaybackRestoration()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Reopening the app from an automatic PiP session may leave the popup binding true,
            // so there is no false→true popup transition to observe. Foreground activation is
            // the second explicit signal that the same video should return inline.
            if phase == .active, player.fullScreenPresented {
                player.requestInlinePlaybackRestoration()
            }
        }
        // Menu-bar / keyboard-shortcut driven tab switching from `MacCommands`. The
        // notification is meaningful only on Mac (where the menu bar exists) and on iPad
        // with a hardware keyboard; everywhere else nobody posts it and this is a no-op.
        .onReceive(NotificationCenter.default.publisher(for: .freetubeSelectTab)) { note in
            guard let tab = note.object as? Tab else { return }
            if tab == .settings {
                showingSettings = true
            } else {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .freetubeOpenSettings)) { _ in
            showingSettings = true
        }
        .sheet(isPresented: $showingSettings) {
            SettingsScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .freetubeOpenChannel)) { note in
            guard let channelID = note.object as? String, !channelID.isEmpty else { return }
            routeInSelectedTab(.channel(channelID))
        }
        .onReceive(NotificationCenter.default.publisher(for: .freetubeOpenPlaylist)) { note in
            guard let playlistID = note.object as? String, !playlistID.isEmpty else { return }
            routeInSelectedTab(.playlist(playlistID))
        }
        .onReceive(NotificationCenter.default.publisher(for: .freetubeOpenLocalPlaylist)) { note in
            guard let playlistID = note.object as? String, !playlistID.isEmpty else { return }
            routeInSelectedTab(.localPlaylist(playlistID))
        }
        .onAppear {
            if !showSubscriptionFeedTab, selectedTab == .feed { selectedTab = .search }
            if !showMusicTab, selectedTab == .music { selectedTab = .search }
        }
        .onChange(of: showSubscriptionFeedTab) { _, isVisible in
            if !isVisible, selectedTab == .feed { selectedTab = .search }
        }
        .onChange(of: showMusicTab) { _, isVisible in
            if !isVisible, selectedTab == .music { selectedTab = .search }
        }
    }

    @ViewBuilder
    private var tabShell: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                if showSubscriptionFeedTab {
                    SwiftUI.Tab("Feed", systemImage: "rectangle.stack", value: Tab.feed) {
                        SubscriptionFeedScreen(navigationRequest: feedNavigationRequest)
                    }
                }

                SwiftUI.Tab("Search", systemImage: "magnifyingglass", value: Tab.search) {
                    HomeScreen(searchActivation: searchActivation, navigationRequest: searchNavigationRequest)
                }

                if showMusicTab {
                    SwiftUI.Tab("Music", systemImage: "music.note", value: Tab.music) {
                        MusicScreen(navigationRequest: musicNavigationRequest)
                    }
                }

                SwiftUI.Tab("Library", systemImage: "play.square.stack", value: Tab.library) {
                    LibraryScreen(navigationRequest: libraryNavigationRequest)
                }

                SwiftUI.Tab("Downloads", systemImage: "arrow.down.circle", value: Tab.downloads) {
                    DownloadsScreen(navigationRequest: downloadsNavigationRequest)
                }
                .badge(activeDownloadsCount > 0 ? activeDownloadsCount : 0)
            }
        } else {
            legacyTabShell
        }
    }

    /// iOS 17–25 compatibility. iOS 26 uses the modern `Tab` declarations above for its
    /// native Liquid Glass tab bar, while Search remains an ordinary peer tab on every OS.
    private var legacyTabShell: some View {
        TabView(selection: tabSelection) {
            if showSubscriptionFeedTab {
                SubscriptionFeedScreen(navigationRequest: feedNavigationRequest)
                    .tabItem { Label("Feed", systemImage: "rectangle.stack") }
                    .tag(Tab.feed)
            }

            HomeScreen(searchActivation: searchActivation, navigationRequest: searchNavigationRequest)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            if showMusicTab {
                MusicScreen(navigationRequest: musicNavigationRequest)
                    .tabItem { Label("Music", systemImage: "music.note") }
                    .tag(Tab.music)
            }

            LibraryScreen(navigationRequest: libraryNavigationRequest)
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            DownloadsScreen(navigationRequest: downloadsNavigationRequest)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(activeDownloadsCount > 0 ? activeDownloadsCount : 0)
                .tag(Tab.downloads)
        }
    }

    /// Keep Search as an ordinary peer tab. SwiftUI writes the selection binding even when an
    /// already-selected tab item is tapped, which lets us request search activation without the
    /// detached iOS 26 `.search` tab role or a gesture recognizer on the native tab bar.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .feed, !showSubscriptionFeedTab {
                    selectedTab = .search
                    return
                }
                if newTab == .music, !showMusicTab {
                    selectedTab = .search
                    return
                }
                if newTab == .settings {
                    showingSettings = true
                    return
                }
                if newTab == .search, selectedTab == .search {
                    searchActivation &+= 1
                }
                selectedTab = newTab
            }
        )
    }

    private func routeInSelectedTab(_ destination: AppNavigationRequest.Destination) {
        let request = AppNavigationRequest(destination: destination)
        switch selectedTab {
        case .feed: feedNavigationRequest = request
        case .search: searchNavigationRequest = request
        case .music: musicNavigationRequest = request
        case .library: libraryNavigationRequest = request
        case .downloads: downloadsNavigationRequest = request
        case .settings: break
        }
    }

    private func updateStatusBarOverride(forFullScreenOpen open: Bool) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        window?.overrideUserInterfaceStyle = open ? .dark : .unspecified
    }

    /// Refreshes `thumbnail` whenever the current video changes. Tries three sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flash).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the `Video` object the screen built has `thumbnailURL == nil`).
    ///  3. Async Kingfisher fetch from disk/network if neither of the above hit.
    /// Clears `thumbnail` immediately first so we don't show the previous video's preview while
    /// the new one is loading.
    private func loadThumbnailForCurrentVideo() {
        thumbnail = nil

        guard let video = player.currentVideo else { return }

        // 1. Synchronous in-memory cache for the thumbnail URL.
        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            thumbnail = cached
            return
        }

        // 2. Xattr-stored thumbnail for downloaded videos. `DownloadsStore` keeps the
        // current snapshot in memory, so the lookup is synchronous and the compressed JPEG
        // bytes decode straight to a `UIImage`.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            self.thumbnail = image
            return
        }

        // 3. Async network/disk-cache fetch (in parallel with the xattr lookup above —
        // whichever completes first and matches the current video wins).
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                // Guard against a race: if the user has already switched to another video while
                // this fetch was inflight, don't stomp the new thumbnail with the stale one.
                guard self.player.currentVideo?.id == videoID else { return }
                self.thumbnail = value.image
            }
        }
    }

}

/// Hosts the popup's `FullScreenPlayer` and all of its `popup*(...)` metadata modifiers.
///
/// **Why this exists:** `RootView.popup { ... }` calls its content closure once at popup-presentation
/// time, so captured metadata freezes there. Wrapping the content in a real
/// `View` makes SwiftUI's observation system re-render the body when the player's state changes.
///
/// Progress is deliberately emitted by the leaf `PopupProgressObserver`; keeping that half-second
/// observation out of this wrapper prevents the native title labels from being rebuilt every tick.
/// Made non-private so `MacRootView` can reuse the same popup chrome when running on
/// Mac via "Designed for iPad" — same look as the iOS mini-bar, same drag-to-expand
/// behavior, no duplicated styling.
@available(iOS 17.0, *)
struct PopupContentWrapper: View {
    @Environment(PlayerStateManager.self) private var player
    let thumbnail: UIImage?

    @State private var subtitleText: String = ""

    var body: some View {
        FullScreenPlayer()
            .popupTitle(player.currentVideo?.title ?? "", subtitle: subtitleText)
            .popupImage(image)
            .popupBarLeadingButtons {
                ToolbarItemGroup(placement: .popupBar) {
                    Button {
                        player.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .contentShape(.interaction, Rectangle().inset(by: -10))
                    .accessibilityLabel("Close player")
                }
            }
            // Progress changes every half-second. Isolate that observation from this wrapper so
            // LNPopupUI does not receive a freshly rebuilt title/subtitle on every playback tick;
            // repeatedly resetting its native labels made mini-player text distort or disappear.
            .overlay { PopupProgressObserver() }
            .popupBarButtons {
                ToolbarItemGroup(placement: .popupBar) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color.primary)
                    }
                    .contentShape(.interaction, Rectangle().inset(by: -10))
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
            }
            .onChange(of: player.loadState, initial: true) { old, new in
                // Self.log.info("onChange.loadState old=\(String(describing: old), privacy: .public) new=\(String(describing: new), privacy: .public)")
                subtitleText = computedSubtitle
            }
            .onChange(of: player.currentVideo?.id, initial: true) { old, new in
                // Self.log.info("onChange.video old=\(old ?? "nil", privacy: .public) new=\(new ?? "nil", privacy: .public)")
                subtitleText = computedSubtitle
            }
    }

    /// Static helper for the few external callers that still want a snapshot.
    static func progress(for player: PlayerStateManager) -> Float {
        if case .downloading(let progress, _) = player.loadState {
            return Float(progress ?? 0)
        }
        guard player.duration > 0 else { return 0 }
        return Float(min(1, max(0, player.elapsed / player.duration)))
    }

    private var computedSubtitle: String { subtitle }

    private var subtitle: String {
        switch player.loadState {
        case .resolving:
            return "Preparing…"
        case .downloading(let progress, let phase):
            guard let progress else { return "Processing…" }
            let percent = Int(progress * 100)
            if let phase, phase == "video" || phase == "audio" {
                return "Downloading \(phase) \(percent)%"
            }
            return "Downloading \(percent)%"
        case .failed(let msg):
            return msg
        // `.buffering` reads as the channel name rather than a status: playback has already been
        // requested at that point, so the bar should look like it's playing, not preparing.
        case .idle, .buffering, .readyToPlay:
            return player.currentVideo?.channelName ?? ""
        }
    }

    /// The real thumbnail from the moment of tap. Only a genuine file transfer (`.downloading`,
    /// the legacy yt-dlp fallback) swaps in the download glyph — during resolve and buffering the
    /// thumbnail is already decoded, so showing a placeholder instead only makes the tap feel slow.
    private var image: Image {
        if case .downloading = player.loadState {
            return Image(systemName: "arrow.down.circle.fill")
        }
        if let thumbnail {
            return Image(uiImage: thumbnail)
        }
        return Image(systemName: "play.rectangle.fill")
    }
}
