import Foundation

/// Music-tab entry points into the shared player. Everything downstream — mini-player,
/// lock-screen controls, AirPlay, background audio, watch history — is the existing pipeline; the
/// only differences are the audio-only stream selection and the album-art surface.
@available(iOS 17.0, *)
extension PlayerStateManager {
    /// Plays `track` with the rest of `tracks` as the queue. When the caller hands over a single
    /// song (a tile on Home, a search result) the queue is extended with YouTube Music's radio for
    /// that song so playback keeps going, exactly like tapping a song on music.youtube.com.
    func playMusic(_ track: MusicItem, in tracks: [MusicItem], shuffled: Bool = false, music: any MusicServicing = MusicService.shared) {
        let ordered = tracks.isEmpty || !tracks.contains(where: { $0.id == track.id }) ? [track] : tracks
        let videos = ordered.filter(\.isPlayable).map(\.asVideo)
        guard let start = videos.first(where: { $0.id == track.id }) else { return }

        let container = Playlist(
            id: "music:" + (track.playlistID ?? track.id),
            title: ordered.count > 1 ? String(localized: "Music queue") : String(localized: "Radio"),
            channelID: nil,
            channelName: nil,
            thumbnailURL: track.thumbnailURL,
            videoCount: videos.count,
            viewCount: nil,
            descriptionText: nil,
            isOwnedByUser: false
        )
        loadPlaylist(
            PlaylistDetails(playlist: container, videos: videos, continuationToken: nil),
            startAt: start,
            shuffled: shuffled,
            audioOnly: true
        )

        guard videos.count < 5 else { return }
        Task { [weak self] in
            guard let self else { return }
            let radio = (try? await music.radio(videoID: track.id, playlistID: nil)) ?? []
            guard self.currentVideo?.id == track.id, self.isAudioOnlySession else { return }
            let existing = Set(self.queue.items.map(\.id))
            self.queue.append(contentsOf: radio.filter { !existing.contains($0.id) }.map(\.asVideo))
        }
    }

    /// Saves an audio-only copy for offline listening through the regular download pipeline, so
    /// it shows up in Downloads and is picked up by the resolver's local-file check next time.
    nonisolated static func downloadForOffline(_ track: MusicItem) {
        Task { @MainActor in
            _ = try? await DownloadManager.shared.ensureDownloaded(video: track.asVideo, quality: .audioOnly, priority: .background)
        }
    }
}
