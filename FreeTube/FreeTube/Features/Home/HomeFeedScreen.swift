import Kingfisher
import SwiftUI

/// **Home** tab. Signed in, it is YouTube's own Home — the topic chips, the recommendation
/// feed with its shelves, infinite scroll — the same `FEwhat_to_watch` surface the official app
/// shows. Signed out, YouTube has nothing personal to offer, so the tab shows the latest videos
/// from channels subscribed to locally in this app (the previous "Feed" behaviour).
@available(iOS 17.0, *)
struct HomeFeedScreen: View {
    let navigationRequest: AppNavigationRequest?
    @State private var path = NavigationPath()
    @State private var auth = AuthState.shared
    @State private var youtube = YouTubeHomeViewModel()
    @State private var local = SubscriptionFeedViewModel()
    @Environment(PlayerStateManager.self) private var player

    private var isSignedIn: Bool {
        if case .loggedIn = auth.status { return true }
        return false
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isSignedIn {
                    YouTubeHomeFeedView(model: youtube)
                } else {
                    LocalSubscriptionFeedView(model: local)
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: AppNavigationRequest.Destination.self) { destination in
                switch destination {
                case .channel(let id): ChannelScreen(channelID: id)
                case .playlist(let id): PlaylistScreen(playlistID: id)
                case .localPlaylist(let id): LocalPlaylistScreen(playlistID: id)
                }
            }
            .onChange(of: navigationRequest?.id) { _, _ in
                guard let destination = navigationRequest?.destination else { return }
                path.append(destination)
            }
            .onChange(of: auth.status) { _, _ in
                // Signing in or out swaps the data source; drop whatever the other one cached.
                youtube.invalidate()
            }
            .errorToast(Bindable(youtube).errorState)
        }
    }
}

/// The signed-in feed: chip bar pinned under the title, then cards and shelves.
@available(iOS 17.0, *)
struct YouTubeHomeFeedView: View {
    @Bindable var model: YouTubeHomeViewModel
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.chips.isEmpty {
                    chipBar
                }
                if model.items.isEmpty, model.isLoading {
                    LoadingView()
                } else if model.items.isEmpty, model.hasLoaded {
                    ContentUnavailableView(
                        "Nothing to show",
                        systemImage: "house",
                        description: Text("YouTube returned no recommendations. Pull down to try again.")
                    )
                    .padding(.top, 60)
                }
                ForEach(model.items) { item in
                    switch item {
                    case .video(let video):
                        VideoCard(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)
                    case .shelf(let section):
                        HomeShelfView(section: section)
                            .padding(.bottom, 20)
                    }
                }
                if model.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .task { await model.loadMore() }
                }
                Color.clear.frame(height: 24)
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.load() }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.chips) { chip in
                    let selected = model.selectedChipID == chip.id
                    Button {
                        Task { await model.select(chip) }
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(selected ? Color.primary : Color.primary.opacity(0.08)))
                            .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

/// A titled horizontal shelf (Shorts, Breaking news, …) inside the Home feed.
@available(iOS 17.0, *)
struct HomeShelfView: View {
    let section: HomeFeedSection
    @Environment(PlayerStateManager.self) private var player

    private var isShorts: Bool { section.videos.allSatisfy(\.isShort) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.title {
                Text(title)
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.videos) { video in
                        Button { player.load(video) } label: {
                            if isShorts {
                                ShortTile(video: video)
                            } else {
                                VideoCard(video: video, showsMoreMenu: false)
                                    .frame(width: 280)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }
}

@available(iOS 17.0, *)
private struct ShortTile: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KFImage(video.thumbnailURL)
                .thumbnail(size: CGSize(width: 150, height: 266)) { Color.gray.opacity(0.18) }
                .resizable()
                .scaledToFill()
                .frame(width: 150, height: 266)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(video.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !video.viewCountString.isEmpty {
                Text(video.viewCountString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 150)
    }
}

/// The signed-out feed body: latest videos from locally subscribed channels. Extracted from the
/// former `SubscriptionFeedScreen` so `HomeFeedScreen` owns the navigation stack for both modes.
@available(iOS 17.0, *)
struct LocalSubscriptionFeedView: View {
    @Bindable var model: SubscriptionFeedViewModel
    @Environment(PlayerStateManager.self) private var player
    @AppStorage("showHistoryProgressBars") private var showHistoryProgressBars = true
    @State private var showingLogin = false

    var body: some View {
        List {
            if model.failedChannelCount > 0 {
                Section {
                    Label(
                        "\(model.failedChannelCount) \(model.failedChannelCount == 1 ? "channel" : "channels") couldn’t be refreshed. Cached videos were kept.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(model.videos) { video in
                VideoRow(
                    video: video,
                    showsMoreMenu: true,
                    offersPlayNext: true,
                    playbackProgress: showHistoryProgressBars ? model.playbackProgress[video.id] : nil
                ) {
                    player.load(video)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 8))
            }

            if model.canLoadMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Label("Load more", systemImage: "chevron.down")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .overlay {
            if !model.hasSubscriptions && model.videos.isEmpty {
                ContentUnavailableView {
                    Label("Sign in for your Home feed", systemImage: "house")
                } description: {
                    Text("Signed in, this tab shows YouTube's recommendations for you. Signed out, it shows the latest videos from channels you subscribe to locally — subscribe from a channel page or import a subscriptions CSV in Settings.")
                } actions: {
                    Button("Sign in") { showingLogin = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.videos.isEmpty && !model.isRefreshing {
                ContentUnavailableView(
                    "Nothing new",
                    systemImage: "rectangle.stack",
                    description: Text("Pull down to refresh your subscriptions.")
                )
            } else if model.videos.isEmpty && model.isRefreshing {
                ProgressView("Refreshing subscriptions…")
            }
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .watchHistoryDidChange)) { _ in
            Task { await model.load() }
        }
        .sheet(isPresented: $showingLogin) { LoginScreen() }
    }
}

@available(iOS 17.0, *)
@Observable
@MainActor
final class YouTubeHomeViewModel {
    private(set) var chips: [HomeFeedChip] = []
    private(set) var items: [HomeFeedItem] = []
    private(set) var selectedChipID: String = "all"
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    var errorState: ErrorState?
    private var continuation: String?
    private let service: any HomeFeedServicing

    init(service: any HomeFeedServicing = HomeFeedService()) {
        self.service = service
    }

    var canLoadMore: Bool { continuation != nil && !isLoadingMore && !isLoading }

    func load() async {
        guard !hasLoaded, !isLoading else { return }
        await fetch(chipParams: nil)
    }

    func refresh() async {
        let params = chips.first { $0.id == selectedChipID }?.params
        await fetch(chipParams: params)
    }

    func select(_ chip: HomeFeedChip) async {
        guard chip.id != selectedChipID else { return }
        selectedChipID = chip.id
        await fetch(chipParams: chip.params, keepChips: true)
    }

    func loadMore() async {
        guard let token = continuation, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.more(continuation: token)
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            continuation = page.items.isEmpty ? nil : page.continuation
        } catch {
            continuation = nil
        }
    }

    func invalidate() {
        hasLoaded = false
        items = []
        chips = []
        selectedChipID = "all"
        continuation = nil
    }

    private func fetch(chipParams: String?, keepChips: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.home(chipParams: chipParams)
            items = page.items
            continuation = page.continuation
            if !page.chips.isEmpty {
                chips = page.chips
                if !keepChips, let selected = page.chips.first(where: \.isSelected) {
                    selectedChipID = selected.id
                }
            }
            hasLoaded = true
        } catch {
            errorState = ErrorState(from: error)
            if case YouTubeServiceError.cookieExpired = error {
                await SessionManager.shared.handleExpiredSession()
            }
        }
    }
}
