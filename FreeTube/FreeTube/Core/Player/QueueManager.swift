import Foundation
import OSLog

/// `nonisolated` on purpose. The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
/// would make this class implicitly main-actor isolated and give it an *isolated deinit*. On the
/// iOS 26.2 simulator with Xcode 27 that deinit path
/// (`swift_task_deinitOnExecutorMainActorBackDeploy`) double-frees and aborts the process the
/// first time a `QueueManager` is deallocated — which never happens in the app (it lives on the
/// `PlayerStateManager` singleton) but happens at the end of every unit test. The queue is plain
/// data with no UI dependency, so it has no reason to be actor-isolated.
@available(iOS 17.0, *)
@Observable
nonisolated final class QueueManager {
    enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
    }

    private(set) var items: [Video] = []
    private(set) var currentIndex: Int = 0
    var isShuffleOn: Bool = false {
        didSet { rebuildShuffleOrder() }
    }
    var repeatMode: RepeatMode = .off

    private var shuffleOrder: [Int] = []
    /// IDs explicitly added through "Play next", in FIFO order. Keeping this separate from the
    /// recommendation queue lets repeated actions form A → B → C instead of a LIFO stack.
    private var pendingPlayNextIDs: [String] = []
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "QueueManager")

    var current: Video? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    // MARK: - Mutation

    func replace(with videos: [Video], startAt index: Int = 0) {
        items = videos
        currentIndex = max(0, min(index, videos.count - 1))
        pendingPlayNextIDs = []
        rebuildShuffleOrder()
    }

    func append(_ video: Video) {
        items.append(video)
        rebuildShuffleOrder()
    }

    func append(contentsOf videos: [Video]) {
        guard !videos.isEmpty else { return }
        items.append(contentsOf: videos)
        rebuildShuffleOrder()
    }

    /// Replaces metadata for an existing queue item without changing its position or navigation
    /// state. Direct-URL playback starts from a lightweight seed, then enriches that seed later.
    func updateVideo(_ video: Video) {
        guard let index = items.firstIndex(where: { $0.id == video.id }) else { return }
        items[index] = video
    }

    /// Bounds an endless recommendation queue while retaining enough history for Previous and a
    /// healthy upcoming buffer. Curated queues never call this method.
    func trimAroundCurrent(maxHistory: Int, maxUpcoming: Int) {
        guard items.indices.contains(currentIndex) else { return }
        let lowerBound = max(0, currentIndex - max(0, maxHistory))
        let upperBound = min(items.count, currentIndex + 1 + max(0, maxUpcoming))
        guard lowerBound > 0 || upperBound < items.count else { return }

        let previousCount = items.count
        items = Array(items[lowerBound..<upperBound])
        currentIndex -= lowerBound
        pendingPlayNextIDs.removeAll { id in !items.contains(where: { $0.id == id }) }
        rebuildShuffleOrder()
        log.debug("Trimmed endless queue from \(previousCount, privacy: .public) to \(self.items.count, privacy: .public) items")
    }

    func insertNext(_ video: Video) {
        // "Play next" means repositioning an existing queue item, not duplicating it. Removing
        // an item before the current position shifts the current index left by one.
        if pendingPlayNextIDs.contains(video.id) { return }
        if let existingIndex = items.firstIndex(where: { $0.id == video.id }) {
            guard existingIndex != currentIndex else { return }
            items.remove(at: existingIndex)
            if existingIndex < currentIndex { currentIndex -= 1 }
        }
        let lastPendingIndex = pendingPlayNextIDs
            .compactMap { pendingID in items.firstIndex(where: { $0.id == pendingID }) }
            .filter { $0 > currentIndex }
            .max()
        let insertIndex = min((lastPendingIndex ?? currentIndex) + 1, items.count)
        items.insert(video, at: insertIndex)
        pendingPlayNextIDs.append(video.id)
        rebuildShuffleOrder()
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removedID = items[index].id
        items.remove(at: index)
        pendingPlayNextIDs.removeAll { $0 == removedID }
        if index < currentIndex { currentIndex -= 1 }
        if currentIndex >= items.count { currentIndex = max(0, items.count - 1) }
        rebuildShuffleOrder()
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let video = items.remove(at: source)
        items.insert(video, at: min(destination, items.count))
        rebuildShuffleOrder()
    }

    /// Marks `video` as the current item. If it's already in `items`, updates `currentIndex`. If not,
    /// the video is appended and becomes current. Lets `PlayerStateManager.load(_:)` keep the queue
    /// coherent when the user taps a fresh video from search/home, while preserving the queue when
    /// they navigate via `playNext()` / `playPrevious()` (which both call `load` with a video that's
    /// already in `items` at the freshly-advanced position).
    func setCurrent(_ video: Video) {
        if let idx = items.firstIndex(of: video) {
            currentIndex = idx
        } else {
            items.append(video)
            currentIndex = items.count - 1
            rebuildShuffleOrder()
        }
    }

    // MARK: - Navigation

    /// Number of distinct items remaining before the queue reaches its physical end. Unlike
    /// `upcomingItems`, this intentionally ignores repeat wrapping so recommendation replenishment
    /// still works when repeat-all is enabled.
    func availableUpcomingCount(limit: Int) -> Int {
        guard limit > 0, items.indices.contains(currentIndex) else { return 0 }
        if isShuffleOn, let position = shuffleOrder.firstIndex(of: currentIndex) {
            return min(limit, max(0, shuffleOrder.count - position - 1))
        }
        return min(limit, max(0, items.count - currentIndex - 1))
    }

    /// Peeks at the next `count` videos that would play after the current one, honoring shuffle and
    /// `.all` wrap-around. Used by the player's prefetch loop so we can warm up the next couple of
    /// downloads while the current one plays. `.one` repeat returns no upcoming items (it just
    /// replays the current).
    func upcomingItems(count: Int) -> [Video] {
        guard count > 0, !items.isEmpty, repeatMode != .one else { return [] }

        if isShuffleOn {
            guard let position = shuffleOrder.firstIndex(of: currentIndex) else { return [] }
            var result: [Video] = []
            var idx = position + 1
            while result.count < count {
                if shuffleOrder.indices.contains(idx) {
                    if let v = items[safe: shuffleOrder[idx]] { result.append(v) }
                    idx += 1
                } else if repeatMode == .all, let first = shuffleOrder.first {
                    if let v = items[safe: first] { result.append(v) }
                    idx = 1
                    if result.count >= shuffleOrder.count { break }
                } else {
                    break
                }
            }
            return result
        }

        var result: [Video] = []
        var idx = currentIndex + 1
        while result.count < count {
            if items.indices.contains(idx) {
                result.append(items[idx])
                idx += 1
            } else if repeatMode == .all, !items.isEmpty {
                idx = 0
                if result.count >= items.count { break }
            } else {
                break
            }
        }
        return result
    }

    func advance() -> Video? {
        switch repeatMode {
        case .one:
            return items[safe: currentIndex]
        case .off, .all:
            let nextIndex = nextIndex()
            if let nextIndex {
                currentIndex = nextIndex
                if let current = items[safe: currentIndex] {
                    pendingPlayNextIDs.removeAll { $0 == current.id }
                }
                return items[safe: currentIndex]
            }
            return nil
        }
    }

    func previous() -> Video? {
        let previousIndex = previousIndex()
        if let previousIndex {
            currentIndex = previousIndex
            return items[safe: currentIndex]
        }
        return nil
    }

    private func nextIndex() -> Int? {
        // Explicit Play Next choices take priority even while shuffle is enabled.
        if let pendingID = pendingPlayNextIDs.first,
           let pendingIndex = items.firstIndex(where: { $0.id == pendingID }),
           pendingIndex != currentIndex {
            return pendingIndex
        }
        if isShuffleOn {
            guard let position = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            let nextPosition = position + 1
            if shuffleOrder.indices.contains(nextPosition) {
                return shuffleOrder[nextPosition]
            }
            if repeatMode == .all, let first = shuffleOrder.first {
                return first
            }
            return nil
        }
        let candidate = currentIndex + 1
        if items.indices.contains(candidate) { return candidate }
        if repeatMode == .all, !items.isEmpty { return 0 }
        return nil
    }

    private func previousIndex() -> Int? {
        if isShuffleOn {
            guard let position = shuffleOrder.firstIndex(of: currentIndex) else { return nil }
            let prev = position - 1
            if shuffleOrder.indices.contains(prev) {
                return shuffleOrder[prev]
            }
            return nil
        }
        let candidate = currentIndex - 1
        return items.indices.contains(candidate) ? candidate : nil
    }

    private func rebuildShuffleOrder() {
        let indices = Array(items.indices)
        shuffleOrder = isShuffleOn ? indices.shuffled() : indices
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
