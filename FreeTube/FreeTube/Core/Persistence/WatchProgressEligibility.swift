import Foundation

/// Shared resume-on-play rules for stored watch progress.
///
/// A short opening is treated as unwatched, and the final 30 seconds (or last 5%) are treated as
/// finished so those videos restart from the beginning.
nonisolated enum WatchProgressEligibility {
    static func resumePosition(
        lastPosition: TimeInterval,
        storedDuration: TimeInterval,
        liveDuration: TimeInterval = 0,
        audioOnly: Bool = false
    ) -> TimeInterval? {
        // Songs start at the beginning. A leftover video resume point for the same ID
        // must not seek an audio-only session mid-track.
        guard !audioOnly else { return nil }
        guard lastPosition.isFinite,
              storedDuration.isFinite,
              lastPosition >= 10 else { return nil }
        let knownDuration = liveDuration > 0 ? liveDuration : storedDuration
        guard knownDuration > 0,
              knownDuration - lastPosition >= 30,
              lastPosition < knownDuration * 0.95 else { return nil }
        return lastPosition
    }
}
