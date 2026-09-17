import XCTest
@testable import FreeTube

@available(iOS 17.0, *)
final class PlayerTransportIconTests: XCTestCase {
    func testPendingStartShowsLoadingInsteadOfPlay() {
        let icon = PlayerTransportIcon.resolve(
            hasEnded: false,
            isPlaying: false,
            pendingAutoplay: true,
            isWaitingForPlayback: true
        )

        XCTAssertEqual(icon, .loading)
    }

    func testPredictedPlayingWhileBufferingStillShowsLoading() {
        let icon = PlayerTransportIcon.resolve(
            hasEnded: false,
            isPlaying: true,
            pendingAutoplay: true,
            isWaitingForPlayback: true
        )

        XCTAssertEqual(icon, .loading)
    }

    func testUserPauseDuringLoadShowsPlay() {
        let icon = PlayerTransportIcon.resolve(
            hasEnded: false,
            isPlaying: false,
            pendingAutoplay: false,
            isWaitingForPlayback: true
        )

        XCTAssertEqual(icon, .play)
    }

    func testReadyPlaybackUsesPlayAndPause() {
        XCTAssertEqual(
            PlayerTransportIcon.resolve(
                hasEnded: false,
                isPlaying: true,
                pendingAutoplay: true,
                isWaitingForPlayback: false
            ),
            .pause
        )
        XCTAssertEqual(
            PlayerTransportIcon.resolve(
                hasEnded: false,
                isPlaying: false,
                pendingAutoplay: false,
                isWaitingForPlayback: false
            ),
            .play
        )
    }

    func testEndedShowsReplayEvenIfStillFlaggedWaiting() {
        let icon = PlayerTransportIcon.resolve(
            hasEnded: true,
            isPlaying: false,
            pendingAutoplay: true,
            isWaitingForPlayback: true
        )

        XCTAssertEqual(icon, .replay)
    }

    func testResolvingAndBufferingCountAsWaiting() {
        XCTAssertTrue(PlayerTransportIcon.isWaitingForPlayback(.resolving))
        XCTAssertTrue(PlayerTransportIcon.isWaitingForPlayback(.buffering))
        XCTAssertTrue(PlayerTransportIcon.isWaitingForPlayback(.downloading(progress: 0.2, phase: "video")))
        XCTAssertFalse(PlayerTransportIcon.isWaitingForPlayback(.readyToPlay))
        XCTAssertFalse(PlayerTransportIcon.isWaitingForPlayback(.failed("nope")))
    }
}
