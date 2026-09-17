import Kingfisher
import SwiftUI

/// Album, artist or playlist page: large artwork header, Play / Shuffle, the track list, then
/// the related shelves YouTube returns (other versions, singles, fans might also like…).
@available(iOS 17.0, *)
struct MusicBrowseScreen: View {
    @State private var model: MusicBrowseViewModel
    @Environment(PlayerStateManager.self) private var player

    init(browseID: String) {
        _model = State(initialValue: MusicBrowseViewModel(browseID: browseID))
    }

    var body: some View {
        ScrollView {
            if let page = model.page {
                VStack(alignment: .leading, spacing: 24) {
                    header(page)
                    if !page.tracks.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(page.tracks.enumerated()), id: \.offset) { offset, track in
                                MusicRow(item: track, context: page.tracks, index: isAlbum(page) ? offset + 1 : nil)
                            }
                        }
                    }
                    ForEach(page.shelves) { shelf in
                        MusicShelfView(shelf: shelf)
                    }
                    if let description = page.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.title3.weight(.bold))
                            Text(description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.top, 8)
            } else if model.isLoading {
                LoadingView()
            } else if model.errorState != nil {
                ContentUnavailableView("Couldn't load this page", systemImage: "exclamationmark.triangle")
                    .padding(.top, 60)
            }
        }
        .navigationTitle(model.page?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    private func isAlbum(_ page: MusicPage) -> Bool {
        page.browseID.hasPrefix("MPRE") || page.subtitle?.hasPrefix("Album") == true || page.subtitle?.hasPrefix("EP") == true
    }

    private func header(_ page: MusicPage) -> some View {
        let isArtist = page.browseID.hasPrefix("UC")
        return VStack(spacing: 14) {
            MusicArtwork(url: page.thumbnailURL, kind: isArtist ? .artist : .album, size: 200)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let subtitle = page.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            if let first = playableTracks(page).first {
                HStack(spacing: 12) {
                    Button {
                        player.playMusic(first, in: playableTracks(page))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(.systemBackground))
                    Button {
                        player.playMusic(first, in: playableTracks(page), shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.horizontal, 24)
            } else if isArtist, let topSongs = page.shelves.first(where: { $0.layout == .list })?.items, let first = topSongs.first {
                Button {
                    player.playMusic(first, in: topSongs)
                } label: {
                    Label("Play top songs", systemImage: "play.fill")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .foregroundStyle(Color(.systemBackground))
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func playableTracks(_ page: MusicPage) -> [MusicItem] {
        page.tracks.filter(\.isPlayable)
    }
}
