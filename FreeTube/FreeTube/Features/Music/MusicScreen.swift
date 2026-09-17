import SwiftUI

/// **Music** tab. Mirrors music.youtube.com: a chip row switching between Home / Explore /
/// Library, shelves of square tiles and song rows underneath, and search in the navigation bar.
/// Home and Library are personalised when the YouTube account is signed in; anonymous users get
/// charts and moods, and Library asks them to sign in.
///
/// Playback goes through the shared `PlayerStateManager` in audio-only mode, so the mini-player,
/// lock-screen controls, AirPlay and background audio behave exactly as for videos.
@available(iOS 17.0, *)
struct MusicScreen: View {
    let navigationRequest: AppNavigationRequest?

    @State private var surface: MusicSurface = .home
    @State private var home = MusicSurfaceViewModel(surface: .home)
    @State private var explore = MusicSurfaceViewModel(surface: .explore)
    @State private var library = MusicSurfaceViewModel(surface: .library)
    @State private var search = MusicSearchViewModel()
    @State private var downloads = DownloadsStore.shared
    @State private var path = NavigationPath()
    @State private var isSearchPresented = false
    @State private var showingLogin = false
    @State private var auth = AuthState.shared
    @Environment(PlayerStateManager.self) private var player

    private var isSignedIn: Bool {
        if case .loggedIn = auth.status { return true }
        return false
    }

    private var isSearching: Bool {
        isSearchPresented || search.hasResults || !search.query.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if isSearching {
                    searchResults
                } else {
                    surfaceContent
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search.query, isPresented: $isSearchPresented, prompt: "Search songs, albums, artists")
            .onSubmit(of: .search) { Task { await search.submit() } }
            .onChange(of: search.query) { _, value in
                if value.trimmingCharacters(in: .whitespaces).isEmpty { search.clear() }
            }
            .navigationDestination(for: MusicRoute.self) { route in
                switch route {
                case .browse(let id): MusicBrowseScreen(browseID: id)
                }
            }
            .navigationDestination(for: AppNavigationRequest.Destination.self) { destination in
                switch destination {
                case .channel(let id): ChannelScreen(channelID: id)
                case .playlist(let id): PlaylistScreen(playlistID: id)
                case .localPlaylist(let id): LocalPlaylistScreen(playlistID: id)
                }
            }
            .onChange(of: navigationRequest?.id) { _, _ in
                guard let destination = navigationRequest?.destination else { return }
                // Music-side artist IDs are YouTube channel IDs; route them to the artist page.
                if case .channel(let id) = destination, id.hasPrefix("UC") {
                    path.append(MusicRoute.browse(id))
                } else {
                    path.append(destination)
                }
            }
            .task(id: surface) { await current.load() }
            .refreshable { await current.load(force: true) }
            .onChange(of: auth.status) { _, _ in
                home.invalidate()
                library.invalidate()
                Task { await current.load() }
            }
            .sheet(isPresented: $showingLogin) { LoginScreen() }
            .errorToast(Bindable(current).errorState)
            .errorToast(Bindable(search).errorState)
        }
    }

    private var current: MusicSurfaceViewModel {
        switch surface {
        case .home: return home
        case .explore: return explore
        case .library: return library
        }
    }

    // MARK: - Surfaces

    private var surfaceContent: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            chips
            if surface == .library, !isSignedIn {
                signInPrompt
            } else if current.isLoading, current.shelves.isEmpty {
                LoadingView()
            } else {
                if surface == .library {
                    downloadedShelf
                }
                ForEach(current.shelves) { shelf in
                    MusicShelfView(shelf: shelf)
                }
                if current.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .task { await current.loadMore() }
                }
                if !current.isLoading, current.shelves.isEmpty, current.hasLoaded, surface != .library {
                    ContentUnavailableView("Nothing here yet", systemImage: "music.note")
                        .padding(.top, 40)
                }
            }
            Color.clear.frame(height: 24)
        }
        .padding(.top, 4)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicSurface.allCases) { candidate in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { surface = candidate }
                    } label: {
                        Text(candidate.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(surface == candidate ? Color.primary : Color.primary.opacity(0.08))
                            )
                            .foregroundStyle(surface == candidate ? Color(.systemBackground) : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var signInPrompt: some View {
        ContentUnavailableView {
            Label("Your music library", systemImage: "music.note.house")
        } description: {
            Text("Sign in to see your liked songs, playlists, albums and listening history from YouTube Music.")
        } actions: {
            Button("Sign in") { showingLogin = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    /// Offline songs saved from the Music tab (`DownloadMetadata.audioOnlyFormatID`).
    @ViewBuilder
    private var downloadedShelf: some View {
        let songs = downloads.entries.compactMap { entry -> MusicItem? in
            guard let meta = entry.metadata, meta.formatID == DownloadMetadata.audioOnlyFormatID else { return nil }
            return MusicItem(
                id: meta.videoID,
                kind: .song,
                title: meta.title,
                subtitle: meta.channelName,
                thumbnailURL: nil,
                duration: entry.duration,
                artistBrowseID: nil,
                playlistID: nil
            )
        }
        if !songs.isEmpty {
            MusicShelfView(shelf: MusicShelf(
                id: "downloaded-songs",
                title: String(localized: "Downloaded"),
                subtitle: String(localized: "Available offline"),
                layout: .list,
                items: Array(songs.prefix(20)),
                moreBrowseID: nil
            ))
        }
    }

    // MARK: - Search

    private var searchResults: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MusicSearchFilter.allCases) { filter in
                        Button {
                            search.filter = filter
                        } label: {
                            Text(filter.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(search.filter == filter ? Color.primary : Color.primary.opacity(0.08)))
                                .foregroundStyle(search.filter == filter ? Color(.systemBackground) : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            if search.isLoading {
                LoadingView()
            } else if search.hasResults {
                ForEach(search.shelves) { shelf in
                    MusicShelfView(shelf: shelf, queueContext: shelf.items.filter(\.isPlayable))
                }
            } else if let last = search.lastSubmittedQuery {
                ContentUnavailableView.search(text: last)
                    .padding(.top, 40)
            }
            Color.clear.frame(height: 24)
        }
        .padding(.top, 4)
    }
}
