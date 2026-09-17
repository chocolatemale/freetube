import Foundation

/// Decides when a KVO `.paused` should re-issue `play()` for a still-pending start.
///
/// `pendingAutoplay` means the user already asked for playback. That is not the same as
/// "every pause is a dropped request": natural end and in-flight seeks also pause AVPlayer.
/// Re-issuing `play()` there cancels `AVPlayerItemDidPlayToEndTime` advancement and makes
/// scrub seeks finish with `finished == false`, so neither next-item nor drag-to-resume play.
@available(iOS 17.0, *)
enum PendingAutoplayResume {
    static func shouldResumeOnPause(
        pendingAutoplay: Bool,
        hasEnded: Bool,
        isSeekInFlight: Bool,
        isItemAtNaturalEnd: Bool,
        loadState: PlayerStateManager.LoadState
    ) -> Bool {
        guard pendingAutoplay, !hasEnded, !isSeekInFlight, !isItemAtNaturalEnd else { return false }
        switch loadState {
        case .buffering, .readyToPlay:
            return true
        case .idle, .resolving, .downloading, .failed:
            return false
        }
    }

    static func shouldPlayAfterSeek(pendingAutoplay: Bool, hasEnded: Bool) -> Bool {
        pendingAutoplay && !hasEnded
    }

    static func isItemAtNaturalEnd(current: TimeInterval, duration: TimeInterval) -> Bool {
        guard current.isFinite, duration.isFinite, duration > 0 else { return false }
        return current >= duration - 0.25
    }
}
