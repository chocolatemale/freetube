import XCTest
@testable import FreeTube

@available(iOS 17.0, *)
final class QueueManagerTests: XCTestCase {
    func testPlayNextSelectionsRemainFIFO() {
        let queue = QueueManager()
        let original = [video("a"), video("d")]
        queue.replace(with: original)

        queue.insertNext(video("b"))
        queue.insertNext(video("c"))

        XCTAssertEqual(queue.items.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(queue.advance()?.id, "b")
        XCTAssertEqual(queue.advance()?.id, "c")
    }

    func testPreviousAndNextPreserveNavigationHistory() {
        let queue = QueueManager()
        queue.replace(with: [video("a"), video("b"), video("c")], startAt: 1)

        XCTAssertEqual(queue.previous()?.id, "a")
        XCTAssertEqual(queue.advance()?.id, "b")
    }

    func testReplaceShrinksWithoutLeavingStaleIndices() {
        let queue = QueueManager()
        queue.replace(with: [video("a"), video("b"), video("c"), video("d"), video("e")])
        let snapshot = queue.items
        queue.replace(with: [video("z")])
        XCTAssertEqual(queue.items.map(\.id), ["z"])
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertEqual(queue.upcomingItems(count: 3).count, 0)
    }

    func testRepeatAllWrapsAtQueueEnd() {
        let queue = QueueManager()
        queue.replace(with: [video("a"), video("b")], startAt: 1)
        queue.repeatMode = .all

        XCTAssertEqual(queue.advance()?.id, "a")
    }

    private func video(_ id: String) -> Video {
        Video(
            id: id,
            title: "Video \(id)",
            channelID: "channel",
            channelName: "Channel",
            channelThumbnailURL: nil,
            thumbnailURL: nil,
            duration: 120,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }
}
