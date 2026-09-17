import XCTest
@testable import FreeTube

final class AudioPlaybackDurationTests: XCTestCase {
    func testDoubledPlayerDurationUsesMetadataLength() {
        let duration = AudioPlaybackDuration.resolved(player: 422, metadata: 211)

        XCTAssertEqual(duration, 211, accuracy: 0.001)
    }

    func testMatchingPlayerDurationIsLeftAlone() {
        let duration = AudioPlaybackDuration.resolved(player: 211.2, metadata: 211)

        XCTAssertEqual(duration, 211.2, accuracy: 0.001)
    }

    func testMissingMetadataKeepsPlayerDuration() {
        let duration = AudioPlaybackDuration.resolved(player: 422, metadata: nil)

        XCTAssertEqual(duration, 422, accuracy: 0.001)
    }

    func testUnrelatedLongerPlayerDurationIsNotClamped() {
        let duration = AudioPlaybackDuration.resolved(player: 300, metadata: 120)

        XCTAssertEqual(duration, 300, accuracy: 0.001)
    }

    func testSynthesizesEndOnlyWhenDurationWasClamped() {
        XCTAssertTrue(
            AudioPlaybackDuration.shouldSynthesizeEnd(
                elapsed: 210.9,
                player: 422,
                metadata: 211
            )
        )
        XCTAssertFalse(
            AudioPlaybackDuration.shouldSynthesizeEnd(
                elapsed: 100,
                player: 422,
                metadata: 211
            )
        )
        XCTAssertFalse(
            AudioPlaybackDuration.shouldSynthesizeEnd(
                elapsed: 210.9,
                player: 211,
                metadata: 211
            )
        )
    }
}
