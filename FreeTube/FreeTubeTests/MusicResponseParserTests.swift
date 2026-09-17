import XCTest
@testable import FreeTube

/// Fixtures are trimmed captures of real `WEB_REMIX` responses (2026-09), so these tests pin the
/// parser to YouTube Music's actual renderer layout rather than to a hand-written idea of it.
final class MusicResponseParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONNode {
        let bundle = Bundle(for: MusicResponseParserTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "music-\(name)", withExtension: "json"), "missing fixture \(name)")
        return JSONNode(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    func testHomeCarouselsAndContinuation() throws {
        let page = MusicResponseParser.page(browseID: "FEmusic_home", from: try fixture("home"))
        XCTAssertEqual(page.shelves.map(\.title), ["Rewind, replay", "Hits throughout the decades"])
        XCTAssertTrue(page.shelves.allSatisfy { $0.layout == .carousel })
        XCTAssertNotNil(page.continuation)
        let tile = try XCTUnwrap(page.shelves.first?.items.first)
        XCTAssertEqual(tile.kind, .playlist)
        XCTAssertEqual(tile.title, "Pop Hits")
        XCTAssertTrue(tile.id.hasPrefix("VL"))
        XCTAssertTrue(tile.thumbnailURL?.absoluteString.contains("=w544-h544") ?? false, "art should be upscaled to a crisp square")
    }

    func testAlbumHeaderTracksAndFallbackArt() throws {
        let page = MusicResponseParser.page(browseID: "MPREb_K8qWMWVqXGi", from: try fixture("album"))
        XCTAssertEqual(page.title, "Random Access Memories")
        XCTAssertEqual(page.subtitle, "Album • 2013 • 13 songs • 1 hour, 14 minutes")
        XCTAssertEqual(page.tracks.count, 3)
        let first = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(first.title, "Give Life Back to Music")
        XCTAssertEqual(first.subtitle, "Daft Punk")
        XCTAssertEqual(first.duration, 276)
        XCTAssertEqual(first.kind, .video, "OMV tracks are videos")
        XCTAssertNotNil(first.thumbnailURL, "album rows carry no art of their own; header art is used")
        XCTAssertEqual(first.playlistID?.hasPrefix("OLAK5uy_"), true)
        XCTAssertEqual(page.shelves.map(\.title), ["Other versions", "Releases for you"])
    }

    func testArtistPage() throws {
        let page = MusicResponseParser.page(browseID: "UCRr1xG_2WIDs18a6cIiCxeA", from: try fixture("artist"))
        XCTAssertEqual(page.title, "Daft Punk")
        XCTAssertNotNil(page.thumbnailURL)
        XCTAssertTrue(page.description?.hasPrefix("Daft Punk were a French") ?? false)
        let top = try XCTUnwrap(page.shelves.first)
        XCTAssertEqual(top.title, "Top songs")
        XCTAssertEqual(top.layout, .list)
        XCTAssertEqual(top.moreBrowseID?.hasPrefix("VL"), true)
        XCTAssertEqual(page.shelves.dropFirst().map(\.layout), [.carousel, .carousel])
    }

    func testPlaylistTracks() throws {
        let page = MusicResponseParser.page(browseID: "VLRDCLAK5uy_nSq67AJ2d75MFNJ3j_4ClEtSgC-opBM84", from: try fixture("playlist"))
        XCTAssertEqual(page.title, "Pop Hits")
        XCTAssertEqual(page.tracks.count, 3)
        XCTAssertEqual(page.tracks.first?.title, "drop dead")
        XCTAssertEqual(page.tracks.first?.subtitle, "Olivia Rodrigo")
        XCTAssertEqual(page.tracks.first?.artistBrowseID?.hasPrefix("UC"), true)
    }

    func testSearchTopResultAndLooseRows() throws {
        let result = MusicResponseParser.searchShelves(from: try fixture("search"))
        XCTAssertEqual(result.shelves.map(\.title), ["Top result", "Results"])
        let items = result.shelves.flatMap(\.items)
        XCTAssertEqual(items.first?.kind, .artist)
        XCTAssertEqual(items.first?.title, "Daft Punk")
        let song = try XCTUnwrap(items.first { $0.kind == .song })
        XCTAssertEqual(song.subtitle, "Daft Punk", "card sub-rows inherit the artist name")
        XCTAssertEqual(song.duration, 338)
        let album = try XCTUnwrap(items.first { $0.kind == .album })
        XCTAssertTrue(album.id.hasPrefix("MPREb_"))
    }

    func testRadioQueue() throws {
        let queue = MusicResponseParser.queue(from: try fixture("next"))
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue[1].title, "Get Lucky (feat. Pharrell Williams and Nile Rodgers)")
        XCTAssertEqual(queue[1].duration, 370)
        XCTAssertEqual(queue[1].playlistID, "RDAMVMkhnokW3Mw24")
    }

    func testDurationParsing() {
        XCTAssertEqual(MusicResponseParser.parseDuration("4:36"), 276)
        XCTAssertEqual(MusicResponseParser.parseDuration("1:02:03"), 3723)
        XCTAssertNil(MusicResponseParser.parseDuration("Album"))
        XCTAssertNil(MusicResponseParser.parseDuration(nil))
    }

    func testMusicItemBridgesToVideo() {
        let item = MusicItem(id: "abc", kind: .song, title: "T", subtitle: "Artist", thumbnailURL: nil, duration: 10, artistBrowseID: "UC1", playlistID: nil)
        let video = item.asVideo
        XCTAssertEqual(video.id, "abc")
        XCTAssertEqual(video.channelName, "Artist")
        XCTAssertEqual(video.channelID, "UC1")
        XCTAssertEqual(video.duration, 10)
    }
}

final class MusicServiceAuthTests: XCTestCase {
    func testSapisidHashIsOriginBoundAndStable() {
        let cookies = "SID=x; HSID=y; SAPISID=abc123; __Secure-3PAPISID=abc123"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let music = MusicService.sapisidHash(cookies: cookies, origin: "https://music.youtube.com", now: date)
        let www = MusicService.sapisidHash(cookies: cookies, origin: "https://www.youtube.com", now: date)
        XCTAssertNotNil(music)
        XCTAssertTrue(music?.hasPrefix("SAPISIDHASH 1700000000_") ?? false)
        XCTAssertNotEqual(music, www, "hash must differ per origin")
        // sha1("1700000000 abc123 https://music.youtube.com")
        XCTAssertEqual(music?.count, "SAPISIDHASH 1700000000_".count + 40)
    }

    func testSapisidHashFallsBackToSecureCookieAndRejectsMissing() {
        XCTAssertNotNil(MusicService.sapisidHash(cookies: "__Secure-3PAPISID=zzz", origin: "https://music.youtube.com"))
        XCTAssertNil(MusicService.sapisidHash(cookies: "SID=only", origin: "https://music.youtube.com"))
        XCTAssertNil(MusicService.sapisidHash(cookies: "", origin: "https://music.youtube.com"))
    }
}
