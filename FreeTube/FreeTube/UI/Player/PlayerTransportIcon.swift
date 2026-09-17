import Foundation

/// Center (and mini-player) transport glyph. While a tap has asked for playback but AVPlayer
/// is not ready, YouTube shows a spinner instead of Play — otherwise the unchanged triangle
/// looks like the user still needs to press it.
@available(iOS 17.0, *)
enum PlayerTransportIcon: Equatable {
    case play
    case pause
    case replay
    case loading

    static func resolve(
        hasEnded: Bool,
        isPlaying: Bool,
        pendingAutoplay: Bool,
        isWaitingForPlayback: Bool
    ) -> Self {
        if hasEnded { return .replay }
        if pendingAutoplay && isWaitingForPlayback { return .loading }
        return isPlaying ? .pause : .play
    }

    static func isWaitingForPlayback(_ loadState: PlayerStateManager.LoadState) -> Bool {
        switch loadState {
        case .resolving, .buffering, .downloading:
            return true
        case .idle, .readyToPlay, .failed:
            return false
        }
    }
}
