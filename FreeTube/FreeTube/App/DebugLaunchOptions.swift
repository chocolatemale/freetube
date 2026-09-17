import Foundation

/// Launch-argument hooks for driving the UI without touching the screen — the headless
/// simulator (`xcrun simctl launch … -FTInitialTab music -FTMusicSurface explore`) has no way to
/// tap. Compiled out of Release builds; the arguments land in `UserDefaults` automatically.
enum DebugLaunchOptions {
    #if DEBUG
    private static let defaults = UserDefaults.standard

    /// `-FTInitialTab feed|search|music|library|downloads`
    static var initialTab: RootView.Tab? {
        defaults.string(forKey: "FTInitialTab").flatMap(RootView.Tab.init(rawValue:))
    }

    /// `-FTMusicSurface home|explore|library`
    static var musicSurface: MusicSurface? {
        defaults.string(forKey: "FTMusicSurface").flatMap(MusicSurface.init(rawValue:))
    }

    /// `-FTMusicBrowse <browseId>` opens an artist / album / playlist page on top of the Music tab.
    static var musicBrowseID: String? {
        defaults.string(forKey: "FTMusicBrowse")
    }

    /// `-FTMusicQuery "<text>"` runs a Music search on launch.
    static var musicQuery: String? {
        defaults.string(forKey: "FTMusicQuery")
    }

    /// `-FTMusicPlay <videoId>` starts an audio-only Music session (with radio) on launch.
    static var musicPlayVideoID: String? {
        defaults.string(forKey: "FTMusicPlay")
    }

    /// `-FTMusicDownload <videoId>` saves an audio-only copy on launch.
    static var musicDownloadVideoID: String? {
        defaults.string(forKey: "FTMusicDownload")
    }

    /// `-FTPlay <videoId>` starts an ordinary video in the player on launch. Combine with
    /// `-captionLanguageCode en` to have that caption track switched on automatically.
    static var playVideoID: String? {
        defaults.string(forKey: "FTPlay")
    }
    #else
    static var initialTab: RootView.Tab? { nil }
    static var musicSurface: MusicSurface? { nil }
    static var musicBrowseID: String? { nil }
    static var musicQuery: String? { nil }
    static var musicPlayVideoID: String? { nil }
    static var musicDownloadVideoID: String? { nil }
    static var playVideoID: String? { nil }
    #endif
}
