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

        let cookie = HTTPCookie(properties: [
            .name: "__Secure-3PSIDTS",
            .value: "rotated",
            .domain: ".youtube.com",
            .path: "/"
        ])!
        jar.setCookie(cookie)
        XCTAssertFalse((jar.cookies ?? []).contains { $0.name == "__Secure-3PSIDTS" },
                       "shared jar must not persist session cookies")
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
