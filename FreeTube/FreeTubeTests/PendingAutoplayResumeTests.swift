import XCTest
@testable import FreeTube

@available(iOS 17.0, *)
final class PendingAutoplayResumeTests: XCTestCase {
    func testBufferingPauseResumesPendingStart() {
        XCTAssertTrue(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: true,
                hasEnded: false,
                isSeekInFlight: false,
                isItemAtNaturalEnd: false,
                loadState: .buffering
            )
        )
    }

    func testReadyRebindPauseResumesPendingStart() {
        XCTAssertTrue(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: true,
                hasEnded: false,
                isSeekInFlight: false,
                isItemAtNaturalEnd: false,
                loadState: .readyToPlay
            )
        )
    }

    func testNaturalEndPauseDoesNotResume() {
        XCTAssertFalse(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: true,
                hasEnded: true,
                isSeekInFlight: false,
                isItemAtNaturalEnd: true,
                loadState: .readyToPlay
            )
        )
        XCTAssertFalse(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: true,
                hasEnded: false,
                isSeekInFlight: false,
                isItemAtNaturalEnd: true,
                loadState: .readyToPlay
            )
        )
    }

    func testSeekPauseDoesNotResume() {
        XCTAssertFalse(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: true,
                hasEnded: false,
                isSeekInFlight: true,
                isItemAtNaturalEnd: false,
                loadState: .readyToPlay
            )
        )
    }

    func testUserPauseDoesNotResume() {
        XCTAssertFalse(
            PendingAutoplayResume.shouldResumeOnPause(
                pendingAutoplay: false,
                hasEnded: false,
                isSeekInFlight: false,
                isItemAtNaturalEnd: false,
                loadState: .readyToPlay
            )
        )
    }

    func testSeekAfterEndedPlaysOnceEndedFlagClears() {
        XCTAssertFalse(PendingAutoplayResume.shouldPlayAfterSeek(pendingAutoplay: true, hasEnded: true))
        XCTAssertTrue(PendingAutoplayResume.shouldPlayAfterSeek(pendingAutoplay: true, hasEnded: false))
        XCTAssertFalse(PendingAutoplayResume.shouldPlayAfterSeek(pendingAutoplay: false, hasEnded: false))
    }

    func testItemNearDurationCountsAsNaturalEnd() {
        XCTAssertTrue(PendingAutoplayResume.isItemAtNaturalEnd(current: 119.9, duration: 120))
        XCTAssertFalse(PendingAutoplayResume.isItemAtNaturalEnd(current: 30, duration: 120))
        XCTAssertFalse(PendingAutoplayResume.isItemAtNaturalEnd(current: .nan, duration: 120))
    }
}
