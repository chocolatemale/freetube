import Foundation

/// Topic filter shown above YouTube's Home feed ("All", "Gaming", "Music", …). `params` is the
/// opaque browse parameter YouTube expects back to filter the feed.
struct HomeFeedChip: Identifiable, Hashable, Sendable {
    let title: String
    let params: String?
    let isSelected: Bool

    var continuation: String? = nil

    var id: String {
        if let continuation { return "c:" + continuation }
        if let params { return "p:" + params }
        return (isSelected ? "all:" : "t:") + title
    }
}

/// A titled shelf inside the Home feed (Shorts, Breaking news, "From your subscriptions" …).
struct HomeFeedSection: Identifiable, Sendable {
    let id: String
    let title: String?
    let videos: [Video]
}

/// One page of the signed-in Home feed: the chip bar, the recommended videos in display order
/// (shelves interleaved as sections) and the continuation for infinite scroll.
struct HomeFeedPage: Sendable {
    let chips: [HomeFeedChip]
    let items: [HomeFeedItem]
    let continuation: String?
}

enum HomeFeedItem: Identifiable, Sendable {
    case video(Video)
    case shelf(HomeFeedSection)

    var id: String {
        switch self {
        case .video(let video): return "v-" + video.id
        case .shelf(let section): return "s-" + section.id
        }
    }
}
