import SwiftUI
import SwiftData
import Kingfisher

/// Library is the user's home for everything tied to their YouTube account. When signed in we
/// render the account header followed by a menu of six destinations:
///   - Watch history (`HistoryScreen` backed by `HistoryResponse`)
///   - Playlists (list of user-owned playlists from `AccountLibraryResponse`)
///   - Your videos (the user's own uploads — opens `ChannelScreen(channelID:)`)
///   - Subscriptions (channels you follow — opens `SubscriptionsScreen`)
///   - Liked videos (special playlist `VLLL` — opens `PlaylistScreen`)
///   - Watch later (special playlist `VLWL` — opens `PlaylistScreen`)
///
/// When signed out we show a single sign-in CTA, hide the YouTube menu, and keep the on-device
/// rows visible. When signed in those local rows sit behind a toggle (`showLocalLibrarySection`,
/// default off). Tapping a YouTube menu item while signed out would toast — gate the whole menu.
@available(iOS 17.0, *)
struct LibraryScreen: View {
    let navigationRequest: AppNavigationRequest?
    @State private var libraryModel = LibraryViewModel()
    @State private var accountModel = AccountViewModel()
    @State private var showingLogin = false
    @State private var localHistoryCount = 0
    @State private var localSubscriptions = LocalSubscriptionStore.shared
    @State private var localPlaylistCount = 0
    @State private var path = NavigationPath()
    @AppStorage("showLocalLibrarySection") private var showLocalLibrarySection = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                localHistorySection
                if accountModel.info != nil {
                    menuSection
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .freetubeOpenSettings, object: nil)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: AppNavigationRequest.Destination.self) { destination in
                switch destination {
                case .channel(let id): ChannelScreen(channelID: id)
                case .playlist(let id): PlaylistScreen(playlistID: id)
                case .localPlaylist(let id): LocalPlaylistScreen(playlistID: id)
                }
            }
            .task {
                localHistoryCount = await PersistenceWriter.shared.watchHistoryCount()
                localPlaylistCount = await localPlaylistCountFromStore()
                await accountModel.load()
                if accountModel.info != nil { await libraryModel.load() }
            }
            .refreshable {
                localHistoryCount = await PersistenceWriter.shared.watchHistoryCount()
                localPlaylistCount = await localPlaylistCountFromStore()
                await accountModel.load()
                if accountModel.info != nil { await libraryModel.load() }
            }
            .sheet(isPresented: $showingLogin) {
                LoginScreen()
                    .onDisappear {
                        // After the login sheet closes, re-fetch account info — if cookies
                        // landed, the next `fetchAccountInfo` will return non-nil and the menu
                        // appears immediately.
                        Task {
                            await accountModel.load()
                            await libraryModel.load()
                        }
                    }
            }
            .errorToast(Bindable(libraryModel).errorState)
            .onReceive(NotificationCenter.default.publisher(for: .watchHistoryDidChange)) { _ in
                Task {
                    localHistoryCount = await PersistenceWriter.shared.watchHistoryCount()
                }
            }
            .onChange(of: navigationRequest?.id) { _, _ in
                guard let destination = navigationRequest?.destination else { return }
                path.append(destination)
            }
            .onReceive(NotificationCenter.default.publisher(for: .localPlaylistsDidChange)) { _ in
                Task { localPlaylistCount = await localPlaylistCountFromStore() }
            }
        }
    }

    private func localPlaylistCountFromStore() async -> Int {
        let playlists = await LocalPlaylistService().playlists()
        return playlists.count
    }

    @ViewBuilder
    private var localHistorySection: some View {
        let isSignedIn = accountModel.info != nil
        let showsRows = LocalLibraryVisibility.showsDeviceRows(
            isSignedIn: isSignedIn,
            preferenceEnabled: showLocalLibrarySection
        )
        Section {
            if isSignedIn {
                Toggle("On this device", isOn: $showLocalLibrarySection)
            }
            if showsRows {
                NavigationLink {
                    LocalHistoryScreen()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local history")
                            Text(countSubtitle(localHistoryCount, noun: "video"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    LocalSubscriptionsScreen()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local subscriptions")
                            Text(countSubtitle(localSubscriptions.subscriptions.count, noun: "channel"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    LocalPlaylistsScreen()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local playlists")
                            Text(countSubtitle(localPlaylistCount, noun: "playlist"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            if !isSignedIn {
                Text("On this device")
            }
        }
    }

    // MARK: - Account header

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let info = accountModel.info {
                HStack(spacing: 12) {
                    KFImage(info.avatarURL)
                        .thumbnail(size: CGSize(width: 56, height: 56)) {
                            Circle().fill(.gray.opacity(0.2))
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(info.displayName).font(.headline)
                        if let handle = info.handle, !handle.isEmpty {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign out") {
                        Task {
                            await accountModel.signOut()
                            libraryModel.clear()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    showingLogin = true
                } label: {
                    Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } footer: {
            if accountModel.info == nil {
                Text("Sign in to access your watch history, playlists, liked videos, and Watch Later.")
            }
        }
    }

    // MARK: - Menu

    /// Five destinations as a single section (Movies removed — YouTubeKit doesn't expose it).
    /// Each row renders a custom `HStack { icon, VStack(title, subtitle) }` so we can show a
    /// count under the title. Subtitles are best-effort: when the library response hasn't
    /// loaded yet they read "—" and update reactively once `libraryModel.library` populates.
    @ViewBuilder
    private var menuSection: some View {
        Section {
            menuRow(
                title: "Watch history",
                subtitle: countSubtitle(libraryModel.library?.historyCount, noun: "video"),
                systemImage: "clock.fill"
            ) {
                HistoryScreen()
            }

            menuRow(
                title: "Playlists",
                subtitle: countSubtitle(libraryModel.library?.playlists.count, noun: "playlist"),
                systemImage: "rectangle.stack.fill"
            ) {
                UserPlaylistsScreen(playlists: libraryModel.library?.playlists ?? [])
            }

            menuRow(
                title: "Your videos",
                subtitle: "Your YouTube channel",
                systemImage: "person.crop.rectangle.fill"
            ) {
                if let channelID = libraryModel.library?.userChannelID {
                    ChannelScreen(channelID: channelID)
                } else {
                    EmptyStateView(
                        systemImage: "person.crop.rectangle.fill",
                        title: "No channel detected",
                        message: "Your YouTube channel ID wasn't returned in the library response. Try refreshing the Library screen."
                    )
                }
            }

            menuRow(
                title: "Subscriptions",
                subtitle: "Channels you follow",
                systemImage: "person.2.fill"
            ) {
                SubscribedChannelsScreen()
            }

            // VLLL — YouTube's well-known playlist ID for the signed-in user's Liked Videos.
            menuRow(
                title: "Liked videos",
                subtitle: countSubtitle(libraryModel.library?.likedCount, noun: "video"),
                systemImage: "hand.thumbsup.fill"
            ) {
                PlaylistScreen(playlistID: "VLLL")
            }

            // VLWL — Watch Later.
            menuRow(
                title: "Watch later",
                subtitle: countSubtitle(libraryModel.library?.watchLaterCount, noun: "video"),
                systemImage: "clock.arrow.circlepath"
            ) {
                PlaylistScreen(playlistID: "VLWL")
            }
        }
    }

    /// Custom row builder so we can put the count under the title (the system's `Label` only
    /// shows a single line of text next to its icon). Pushes the given destination in the
    /// surrounding NavigationStack.
    @ViewBuilder
    private func menuRow<Destination: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds the "N videos" / "N playlists" subtitle. When the library response hasn't
    /// returned yet (count is nil), we render "—" rather than a hardcoded "0" so the user can
    /// tell "still loading" from "actually empty".
    private func countSubtitle(_ count: Int?, noun: String) -> String {
        guard let count else { return "—" }
        let plural = count == 1 ? noun : noun + "s"
        return "\(count) \(plural)"
    }
}

/// Device-only watch history. Unlike `HistoryScreen`, this never calls YouTube and is available
/// without signing in. Rows are backed by `WatchHistoryEntry`, which `PlayerStateManager` updates
/// whenever a video is opened.
@available(iOS 17.0, *)
private struct LocalHistoryScreen: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var entries: [WatchHistorySnapshot] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @AppStorage("showHistoryProgressBars") private var showHistoryProgressBars = true
    private let pageSize = 50

    var body: some View {
        Group {
            if entries.isEmpty && isLoading {
                LoadingView()
            } else if entries.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "No local history",
                    message: "Videos you watch will appear here only on this device."
                )
            } else {
                List {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                VideoRow(
                                    video: video(from: entry),
                                    showsMoreMenu: true,
                                    offersPlayNext: true,
                                    playbackProgress: showHistoryProgressBars ? playbackProgress(for: entry) : nil
                                ) {
                                    player.load(video(from: entry))
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task {
                                            await PersistenceWriter.shared.deleteWatchHistory(videoID: entry.videoID)
                                            entries.removeAll { $0.videoID == entry.videoID }
                                        }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .onAppear {
                                    if entry.videoID == entries.last?.videoID {
                                        Task { await loadMore() }
                                    }
                                }
                            }
                        } header: {
                            Text(dayTitle(group.day))
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Local History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if entries.isEmpty && hasMore { await loadMore() }
        }
    }

    private var dayGroups: [(day: Date, entries: [WatchHistorySnapshot])] {
        let calendar = Calendar.autoupdatingCurrent
        return Dictionary(grouping: entries) { calendar.startOfDay(for: $0.watchedAt) }
            .map { (day: $0.key, entries: $0.value.sorted { $0.watchedAt > $1.watchedAt }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(date: .long, time: .omitted)
    }

    private func video(from entry: WatchHistorySnapshot) -> Video {
        Video(
            id: entry.videoID,
            title: entry.title,
            channelID: "",
            channelName: entry.channelName,
            channelThumbnailURL: nil,
            thumbnailURL: entry.thumbnailURL,
            duration: entry.duration > 0 ? entry.duration : nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }

    /// Match `PlayerStateManager.applyStoredResumePosition` exactly so a row never advertises
    /// progress for a video that playback considers finished or too close to an endpoint.
    private func playbackProgress(for entry: WatchHistorySnapshot) -> Double? {
        entry.resumableProgress
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        let page = await PersistenceWriter.shared.fetchWatchHistory(
            offset: entries.count,
            limit: pageSize
        )
        let existingIDs = Set(entries.map(\.videoID))
        entries.append(contentsOf: page.filter { !existingIDs.contains($0.videoID) })
        hasMore = page.count == pageSize
    }
}

// MARK: - User playlists list

/// Simple list of user-owned playlists. Each row pushes `PlaylistScreen` for the playlist's
/// detail view (videos + actions). Reuses `PlaylistRow` so the visual matches search/channel.
@available(iOS 17.0, *)
private struct UserPlaylistsScreen: View {
    let playlists: [Playlist]

    var body: some View {
        Group {
            if playlists.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.stack",
                    title: "No playlists",
                    message: "Playlists you create on YouTube will appear here."
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist, showsMoreMenu: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}
