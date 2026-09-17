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

        // Ordinary videos and news remain; Shorts and duplicate videos are removed.
        XCTAssertEqual(page.items.count, 3)
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

        guard case .shelf(let news) = page.items[2] else { return XCTFail("third item should be the news shelf") }
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
    func testModernVideoAndChipsWithContinuationEndpoints() throws {
        let root = JSONNode([
            "contents": ["richGridRenderer": [
                "header": ["feedFilterChipBarRenderer": ["contents": [
                    ["chipCloudChipRenderer": ["text": ["simpleText": "All"], "isSelected": true]],
                    ["chipCloudChipRenderer": ["text": ["simpleText": "Music"], "navigationEndpoint": ["continuationCommand": ["token": "MUSIC_PAGE"]]]],
                    ["chipCloudChipRenderer": ["text": ["simpleText": "Gaming"], "navigationEndpoint": ["continuationCommand": ["token": "GAMING_PAGE"]]]]
                ]]],
                "contents": [["richItemRenderer": ["content": ["lockupViewModel": [
                    "contentId": "modern12345", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "A normal video"]]],
                    "contentImage": ["thumbnailViewModel": ["image": ["sources": [["url": "https://i.ytimg.com/vi/modern12345/hqdefault.jpg"]]]]]
                ]]]]]
            ]]
        ])
        let page = HomeFeedParser.page(from: root)
        XCTAssertEqual(Set(page.chips.map(\.id)).count, 3)
        XCTAssertEqual(page.items.count, 1)
        guard let item = page.items.first, case .video(let video) = item else { return XCTFail("missing modern video") }
        XCTAssertEqual(video.title, "A normal video")
        XCTAssertEqual(video.id, "modern12345")
        XCTAssertFalse(video.isShort)
        XCTAssertNotNil(video.thumbnailURL)
    }

    func testShortsLockupAndTitleOnlyShelfAreDropped() {
        let root = JSONNode([
            "contents": ["richGridRenderer": ["contents": [
                ["richItemRenderer": ["content": ["lockupViewModel": [
                    "contentId": "shortLockup1",
                    "contentType": "LOCKUP_CONTENT_TYPE_SHORTS",
                    "metadata": ["lockupMetadataViewModel": ["title": ["content": "A short"]]]
                ]]]],
                ["richItemRenderer": ["content": ["shortsLockupViewModel": [
                    "onTap": ["innertubeCommand": ["reelWatchEndpoint": ["videoId": "shortReel01"]]]
                ]]]],
                ["richSectionRenderer": ["content": ["richShelfRenderer": [
                    "title": ["simpleText": "Shorts"],
                    "contents": [["richItemRenderer": ["content": ["videoRenderer": [
                        "videoId": "shelfShort01",
                        "title": ["simpleText": "Still a short"]
                    ]]]]]
                ]]]]
            ]]]
        ])
        let page = HomeFeedParser.page(from: root)
        XCTAssertTrue(page.items.isEmpty)
    }

}
