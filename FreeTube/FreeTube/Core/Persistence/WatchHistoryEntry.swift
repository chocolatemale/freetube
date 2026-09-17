import Foundation
import SwiftData

extension Notification.Name {
    static let watchHistoryDidChange = Notification.Name("com.leshko.freetube.watchHistoryDidChange")
}

@available(iOS 17.0, *)
@Model
final class WatchHistoryEntry {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelName: String
    var thumbnailURL: URL?
    var watchedAt: Date
    var lastPosition: TimeInterval
    /// Total duration of the video at the moment `lastPosition` was last written. Stored so we
    /// can render a progress bar on cards without re-fetching duration from YouTube, and so
    /// resume-on-tap can skip entries that already reached the end. Default 0 — SwiftData
    /// lightweight migration fills existing rows with this on first read after the upgrade.
    var duration: TimeInterval = 0

    init(
        videoID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?,
        watchedAt: Date = .now,
        lastPosition: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.watchedAt = watchedAt
        self.lastPosition = lastPosition
        self.duration = duration
    }
}

@available(iOS 17.0, *)
extension WatchHistoryEntry {
    /// The same eligibility rules used when playback restores a saved position.
    var resumableProgress: Double? {
        guard let position = WatchProgressEligibility.resumePosition(
            lastPosition: lastPosition,
            storedDuration: duration
        ) else { return nil }
        return position / duration
    }
}

/// Sendable read model used by the paginated History UI. SwiftData model instances stay bound to
/// their model context and never cross the persistence actor boundary.
struct WatchHistorySnapshot: Identifiable, Sendable, Codable {
    var id: String { videoID }
    let videoID: String
    let title: String
    let channelName: String
    let thumbnailURL: URL?
    let watchedAt: Date
    let lastPosition: TimeInterval
    let duration: TimeInterval

    var resumableProgress: Double? {
        guard let position = WatchProgressEligibility.resumePosition(
            lastPosition: lastPosition,
            storedDuration: duration
        ) else { return nil }
        return position / duration
    }
}
