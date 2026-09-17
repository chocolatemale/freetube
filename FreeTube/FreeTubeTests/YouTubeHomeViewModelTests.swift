import XCTest
@testable import FreeTube

@available(iOS 17.0, *)
@MainActor
final class YouTubeHomeViewModelTests: XCTestCase {
    func testPullToRefreshRebrowsesHomeInsteadOfReplayingChipContinuation() async throws {
        let service = MockHomeFeedService()
        let model = YouTubeHomeViewModel(service: service)

        await model.load()
        XCTAssertEqual(service.homeCalls, 1)
        XCTAssertEqual(service.moreCalls, 0)
        XCTAssertFalse(model.chips.isEmpty)
        XCTAssertNotNil(model.chips.first?.continuation)

        await model.refresh()

        XCTAssertEqual(service.homeCalls, 2, "refresh must browse FEwhat_to_watch again")
        XCTAssertEqual(service.moreCalls, 0, "chip continuation is for switching chips, not pull-to-refresh")
        XCTAssertEqual(service.lastHomeParams, nil)
    }

    func testPullToRefreshKeepsChipFilterViaBrowseParams() async throws {
        let service = MockHomeFeedService()
        let model = YouTubeHomeViewModel(service: service)
        await model.load()

        let gaming = try XCTUnwrap(model.chips.first { $0.title == "Gaming" })
        await model.select(gaming)
        XCTAssertEqual(service.lastHomeParams, "GAMING_PARAMS")

        let homesBefore = service.homeCalls
        await model.refresh()

        XCTAssertEqual(service.homeCalls, homesBefore + 1)
        XCTAssertEqual(service.lastHomeParams, "GAMING_PARAMS")
        XCTAssertEqual(service.moreCalls, 0)
    }
}

@available(iOS 17.0, *)
private final class MockHomeFeedService: HomeFeedServicing, @unchecked Sendable {
    var homeCalls = 0
    var moreCalls = 0
    var lastHomeParams: String?

    func home(chipParams: String?) async throws -> HomeFeedPage {
        homeCalls += 1
        lastHomeParams = chipParams
        return HomeFeedPage(
            chips: [
                HomeFeedChip(title: "All", params: nil, isSelected: chipParams == nil, continuation: "CHIP_ALL_CONT"),
                HomeFeedChip(title: "Gaming", params: "GAMING_PARAMS", isSelected: chipParams == "GAMING_PARAMS")
            ],
            items: [.video(video(chipParams == "GAMING_PARAMS" ? "game" : "home"))],
            continuation: "PAGE_MORE"
        )
    }

    func more(continuation: String) async throws -> HomeFeedPage {
        moreCalls += 1
        return HomeFeedPage(
            chips: [],
            items: [.video(video("more"))],
            continuation: nil
        )
    }

    private func video(_ id: String) -> Video {
        Video(
            id: id,
            title: "Video \(id)",
            channelID: "channel",
            channelName: "Channel",
            channelThumbnailURL: nil,
            thumbnailURL: nil,
            duration: 60,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
    }
}
