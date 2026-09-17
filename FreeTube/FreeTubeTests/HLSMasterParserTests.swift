import XCTest
@testable import FreeTube

final class HLSMasterParserTests: XCTestCase {
    func testPicksDefaultAudioRenditionAndIgnoresDubbed() throws {
        let master = """
        #EXTM3U
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="https://manifest.googlevideo.com/audio-en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English dubbed",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="https://manifest.googlevideo.com/audio-dub.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="audio",CODECS="avc1.4d401f,mp4a.40.2"
        https://manifest.googlevideo.com/video-720.m3u8
        """

        let url = HLSMasterParser.preferredAudioURL(
            playlist: master,
            baseURL: URL(string: "https://manifest.googlevideo.com/master.m3u8")!
        )

        XCTAssertEqual(url?.absoluteString, "https://manifest.googlevideo.com/audio-en.m3u8")
    }

    func testResolvesRelativeAudioURI() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Default",DEFAULT=YES,URI="playlist/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"
        playlist/video.m3u8
        """

        let url = HLSMasterParser.preferredAudioURL(
            playlist: master,
            baseURL: URL(string: "https://example.com/hls/master.m3u8")!
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/hls/playlist/audio.m3u8")
    }

    func testReturnsNilWhenMasterHasNoAudioRendition() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.42c01e,mp4a.40.2"
        https://example.com/muxed.m3u8
        """

        XCTAssertNil(
            HLSMasterParser.preferredAudioURL(
                playlist: master,
                baseURL: URL(string: "https://example.com/master.m3u8")!
            )
        )
    }
}
