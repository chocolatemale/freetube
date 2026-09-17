import Foundation

/// One tile or row on a YouTube Music surface. Songs and videos are playable directly; albums,
/// artists and playlists open a `MusicPage`.
struct MusicItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case song, video, album, artist, playlist
    }

    /// `videoId` for songs/videos, `browseId` for albums/artists/playlists.
    let id: String
    let kind: Kind
    let title: String
    /// Artist names for songs/albums, "Artist" / listener count for artists, owner for playlists.
    let subtitle: String
    let thumbnailURL: URL?
    let duration: TimeInterval?
    /// Artist `browseId` when the subtitle links to one — lets a row open the artist page.
    let artistBrowseID: String?
    /// For songs that came from a playlist/album, the container to queue alongside.
    let playlistID: String?

    var isPlayable: Bool { kind == .song || kind == .video }

    /// Bridges into the shared player: `channelName` doubles as the artist line and the square
    /// album art becomes the thumbnail. `channelID` carries the artist `browseId` so the player's
    /// "open channel" action lands on the artist page.
    var asVideo: Video {
        Video(
            id: id,
            title: title,
            channelID: artistBrowseID ?? "",
            channelName: subtitle,
            channelThumbnailURL: nil,
            thumbnailURL: thumbnailURL,
            duration: duration,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }
}

/// A titled group of items — YouTube Music's carousels ("Quick picks", "Listen again"), lists
/// ("Top songs") and grids (library).
struct MusicShelf: Identifiable, Hashable, Sendable {
    enum Layout: Sendable {
        /// Horizontally scrolling square tiles.
        case carousel
        /// Vertical rows with small square art (songs).
        case list
        /// Two-column grid of tiles (library landing).
        case grid
    }

    let id: String
    let title: String
    let subtitle: String?
    let layout: Layout
    let items: [MusicItem]
    /// `browseId` of a "More" page when YouTube offers one.
    let moreBrowseID: String?
}

/// A browse page: artist, album, playlist, or one of the fixed surfaces (home, explore, library).
struct MusicPage: Sendable {
    let browseID: String
    let title: String
    let subtitle: String?
    let description: String?
    let thumbnailURL: URL?
    /// Tracks listed directly on the page (album/playlist body, artist top songs).
    let tracks: [MusicItem]
    let shelves: [MusicShelf]
    let continuation: String?
}

/// Search facets mirroring the chips on music.youtube.com. The `params` values come from the
/// chip cloud YouTube returns; they have been stable for years.
enum MusicSearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all, songs, videos, albums, artists, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .songs: return String(localized: "Songs")
        case .videos: return String(localized: "Videos")
        case .albums: return String(localized: "Albums")
        case .artists: return String(localized: "Artists")
        case .playlists: return String(localized: "Playlists")
        }
    }

    var params: String? {
        switch self {
        case .all: return nil
        case .songs: return "EgWKAQIIAWoSEAUQCRADEAQQChAQEA4QFRAR"
        case .videos: return "EgWKAQIQAWoSEAUQCRADEAQQChAQEA4QFRAR"
        case .albums: return "EgWKAQIYAWoSEAUQCRADEAQQChAQEA4QFRAR"
        case .artists: return "EgWKAQIgAWoSEAUQCRADEAQQChAQEA4QFRAR"
        case .playlists: return "EgeKAQQoAEABahIQBRAJEAMQBBAKEBAQDhAVEBE%3D"
        }
    }
}

/// Fixed browse surfaces exposed by the Music tab's top segmented control.
enum MusicSurface: String, CaseIterable, Identifiable, Sendable {
    case home, explore, library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .explore: return String(localized: "Explore")
        case .library: return String(localized: "Library")
        }
    }

    var browseID: String {
        switch self {
        case .home: return "FEmusic_home"
        case .explore: return "FEmusic_explore"
        case .library: return "FEmusic_library_landing"
        }
    }

    var requiresAccount: Bool { self == .library }
}
