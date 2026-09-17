import Foundation

/// YouTube's itag 140 AAC DASH `m4a` often ships an empty time-to-sample atom.
/// AVPlayer then reports about twice the real length and plays silence in the
/// second half. Music metadata still carries the true duration, so audio-only
/// playback can display and end at that length instead of waiting out the pad.
nonisolated enum AudioPlaybackDuration {
    static func resolved(player: TimeInterval, metadata: TimeInterval?) -> TimeInterval {
        guard player.isFinite, player > 0 else { return 0 }
        guard let metadata, metadata.isFinite, metadata > 0 else { return player }
        let ratio = player / metadata
        if ratio >= 1.8, ratio <= 2.2 {
            return metadata
        }
        return player
    }

    static func shouldSynthesizeEnd(
        elapsed: TimeInterval,
        player: TimeInterval,
        metadata: TimeInterval?
    ) -> Bool {
        guard elapsed.isFinite, player.isFinite, player > 0 else { return false }
        let duration = resolved(player: player, metadata: metadata)
        guard duration > 0, player - duration > 1 else { return false }
        return elapsed >= duration - 0.25
    }
}
