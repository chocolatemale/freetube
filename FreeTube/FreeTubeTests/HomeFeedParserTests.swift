import XCTest
@testable import FreeTube

/// The fixture wraps real `videoRenderer` nodes (captured from the WEB client) in the
/// `richGridRenderer` layout YouTube uses for `FEwhat_to_watch`: chip bar, rich items, shelves
/// (a Shorts shelf using `shortsLockupViewModel`, a titled video shelf) and a continuation.
final class HomeFeedParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONNode {
        let bundle = Bundle(for: HomeFeedParserTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return JSONNode(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    func testChipsVideosShelvesAndContinuation() throws {
        let page = HomeFeedParser.page(from: try fixture("home-feed"))

        XCTAssertEqual(page.chips.map(\.title), ["All", "Gaming", "Music"])
        XCTAssertEqual(page.chips.first?.isSelected, true)
        XCTAssertNil(page.chips.first?.params)
        XCTAssertEqual(page.chips[1].params, "GAMING_PARAMS")

        XCTAssertEqual(page.continuation, "CONT_TOKEN_1")

        // 2 videos, Shorts shelf, news shelf; the duplicated video is dropped.
        XCTAssertEqual(page.items.count, 4)
        guard case .video(let first) = page.items[0] else { return XCTFail("first item should be a video") }
        XCTAssertEqual(first.id, "1JkzrR-hznE")
        XCTAssertTrue(first.title.hasPrefix("How ASML Makes Chips"))
        XCTAssertEqual(first.channelName, "CNBC")
        XCTAssertTrue(first.channelID.hasPrefix("UC"))
        XCTAssertEqual(first.duration, 17 * 60 + 25)
        XCTAssertEqual(first.viewCount, 3_575_774)
        XCTAssertEqual(first.publishedRelative, "1 year ago")
        XCTAssertNotNil(first.thumbnailURL)
        XCTAssertNotNil(first.channelThumbnailURL)

        guard case .shelf(let shorts) = page.items[2] else { return XCTFail("third item should be the Shorts shelf") }
        XCTAssertEqual(shorts.title, "Shorts")
        XCTAssertEqual(shorts.videos.first?.id, "abc123XYZ00")
        XCTAssertEqual(shorts.videos.first?.isShort, true)
        XCTAssertEqual(shorts.videos.first?.viewCount, 1_200_000)

        guard case .shelf(let news) = page.items[3] else { return XCTFail("fourth item should be the news shelf") }
        XCTAssertEqual(news.title, "Breaking news")
        XCTAssertEqual(news.videos.count, 2)
    }

    func testContinuationPayload() throws {
        let page = HomeFeedParser.page(from: try fixture("home-feed-continuation"))
        XCTAssertTrue(page.chips.isEmpty)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.continuation, "CONT_TOKEN_2", "commandExecutorCommand-wrapped tokens are read too")
    }

    func testAnonymousNudgeYieldsEmptyPage() {
        let root = JSONNode(["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["richGridRenderer": ["contents": [["richSectionRenderer": ["content": ["feedNudgeRenderer": [:]]]]]]]]]]]]])
        let page = HomeFeedParser.page(from: root)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.continuation)
    }
}
