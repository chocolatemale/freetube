import XCTest
@testable import FreeTube

final class SecurityHardeningTests: XCTestCase {
    // MARK: URL redaction

    func testRedactedURLDropsQueryButKeepsHostAndPath() {
        let url = URL(string: "https://accounts.google.com/v3/signin/challenge/pwd?TL=SECRET&continue=https%3A%2F%2Fyoutube.com")!
        XCTAssertEqual(SecurityHardening.redactedForLog(url), "https://accounts.google.com/v3/signin/challenge/pwd?…")
    }

    func testRedactedURLWithoutQueryIsUnchangedShape() {
        let url = URL(string: "https://rr1---sn-abc.googlevideo.com/videoplayback")!
        XCTAssertEqual(SecurityHardening.redactedForLog(url), "https://rr1---sn-abc.googlevideo.com/videoplayback")
    }

    func testRedactedURLHandlesNil() {
        XCTAssertEqual(SecurityHardening.redactedForLog(nil), "?")
    }

    // MARK: Shared cookie jar

    func testSharedCookieJarRejectsCookiesAfterConfiguration() {
        SecurityHardening.configureAtLaunch()
        let jar = HTTPCookieStorage.shared
        XCTAssertEqual(jar.cookieAcceptPolicy, .never)

        // `cookieAcceptPolicy` governs cookies arriving from URL loading — the path
        // `Set-Cookie` headers take — not the explicit `setCookie(_:)` API.
        let cookie = HTTPCookie(properties: [
            .name: "__Secure-3PSIDTS",
            .value: "rotated",
            .domain: ".youtube.com",
            .path: "/"
        ])!
        let url = URL(string: "https://www.youtube.com/youtubei/v1/browse")!
        jar.setCookies([cookie], for: url, mainDocumentURL: url)
        XCTAssertFalse((jar.cookies ?? []).contains { $0.name == "__Secure-3PSIDTS" },
                       "shared jar must not persist session cookies")
        XCTAssertTrue((jar.cookies(for: url) ?? []).isEmpty)
    }

    func testPythonEnvironmentPointsAtBundledCABundle() {
        SecurityHardening.configureAtLaunch()
        let value = ProcessInfo.processInfo.environment["SSL_CERT_FILE"]
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.hasSuffix("cacert.pem") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: value ?? ""))
    }

    func testDiagnosticsDirectoryIsNotUnderDocuments() {
        let dir = SecurityHardening.diagnosticsDirectory.path
        XCTAssertFalse(dir.contains("/Documents/"))
        XCTAssertTrue(dir.contains("Application Support"))
    }

    // MARK: AppLog redaction

    func testUnannotatedInterpolationIsRedacted() {
        let secret = "SAPISID=abc"
        let message: AppLogMessage = "value=\(secret)"
        XCTAssertEqual(message.renderedText, "value=<private>")
    }

    func testPublicInterpolationIsKept() {
        let message: AppLogMessage = "count=\(3, privacy: .public)"
        XCTAssertEqual(message.renderedText, "count=3")
    }
}

final class YtDlpChecksumTests: XCTestCase {
    private let sums = """
    1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
    66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a  yt-dlp.exe
    072aad4f2a7604e92155f61a275a4752dc64046c8f6d90df3710525d94cd37c1  yt-dlp.tar.gz
    """

    func testFindsExactFilenameNotPrefixMatches() {
        XCTAssertEqual(
            YtDlpUpdater.expectedDigest(in: sums, for: "yt-dlp"),
            "1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6"
        )
        XCTAssertEqual(
            YtDlpUpdater.expectedDigest(in: sums, for: "yt-dlp.exe"),
            "66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a"
        )
    }

    func testMissingEntryReturnsNil() {
        XCTAssertNil(YtDlpUpdater.expectedDigest(in: sums, for: "yt-dlp_linux"))
    }

    func testMalformedDigestReturnsNil() {
        XCTAssertNil(YtDlpUpdater.expectedDigest(in: "nothex  yt-dlp", for: "yt-dlp"))
        XCTAssertNil(YtDlpUpdater.expectedDigest(in: "abcd  yt-dlp", for: "yt-dlp"))
    }
}

final class PythonJSBridgeTests: XCTestCase {
    func testDisablesPreprocessedPlayerOutputRegardlessOfSpacing() {
        for input in [
            #"{"output_preprocessed":true,"responses":[]}"#,
            #"{"output_preprocessed": true, "responses": []}"#,
            #"{"output_preprocessed" :true}"#
        ] {
            let result = PythonJSBridge.withoutPreprocessedPlayerCache(input)
            XCTAssertTrue(result.contains(#""output_preprocessed":false"#), input)
            XCTAssertFalse(result.contains("true"), input)
        }
    }

    func testLeavesUnrelatedPayloadAlone() {
        let input = #"{"output_preprocessed":false,"other":true}"#
        XCTAssertEqual(PythonJSBridge.withoutPreprocessedPlayerCache(input), input)
    }
}

final class CaptionServiceTests: XCTestCase {
    func testParsesJSON3EventsAndSkipsWindowDefinitions() {
        let json = """
        {"events":[
          {"tStartMs":0,"dDurationMs":100,"id":1,"wpWinPosId":1,"wsWinStyleId":1},
          {"tStartMs":1200,"dDurationMs":2160,"segs":[{"utf8":"All right, so here we are,"},{"utf8":" in front of\\nthe elephants"}]},
          {"tStartMs":3360,"dDurationMs":200,"segs":[{"utf8":"\\n"}]},
          {"tStartMs":4000,"segs":[{"utf8":"cool"}]}
        ]}
        """
        let cues = CaptionService.parseJSON3(Data(json.utf8))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.2)
        XCTAssertEqual(cues[0].end, 3.36, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "All right, so here we are, in front of the elephants")
        XCTAssertEqual(cues[1].start, 4.0)
        XCTAssertEqual(cues[1].end, 4.5, accuracy: 0.001, "events without a duration get a 500 ms floor")
    }

    func testMalformedJSON3YieldsNoCues() {
        XCTAssertTrue(CaptionService.parseJSON3(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(CaptionService.parseJSON3(Data("{}".utf8)).isEmpty)
    }
}
