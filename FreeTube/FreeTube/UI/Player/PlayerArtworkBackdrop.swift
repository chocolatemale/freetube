import SwiftUI
import UIKit

/// Paints the current video's thumbnail into the player area for as long as AVPlayer has no frame
/// to show, then gets out of the way.
///
/// This is the perception half of the startup work. Resolution is down to ~0.4s on a warm cache but
/// AVPlayer still needs ~2s to reach `.readyToPlay`, and AVPlayer exposes no "first frame rendered"
/// signal we could paint against, so the wait can't be removed — only covered. NewPipe gets its
/// "instant" feel the same way: the thumbnail the user just tapped is already decoded in memory, so
/// showing it means the player area is never a black rectangle and never a spinner with a label.
///
/// Ordered *above* `PlayerSurface` in the ZStack on purpose — `AVPlayerViewController`'s view paints
/// its own opaque black background, so anything underneath it is invisible. `allowsHitTesting(false)`
/// keeps the system playback controls reachable through the artwork.
///
/// For audio-only (Music tab) sessions the stream has no video track, so the artwork stays up for
/// the whole playback and is fitted rather than filled — album art is square.
@available(iOS 17.0, *)
struct PlayerArtworkBackdrop: View {
    let artwork: UIImage?
    let state: PlayerStateManager.LoadState
    var isAudioOnly: Bool = false

    var body: some View {
        if isAudioOnly, artwork == nil {
            // Audio-only with no art yet: still cover AVPlayer's QuickTime placeholder glyph.
            ZStack {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        } else if coversPlayerSurface, let artwork {
            ZStack {
                if isAudioOnly {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 40)
                        .opacity(0.55)
                        .clipped()
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(16)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
                } else {
                    Image(uiImage: artwork)
                        .resizable()
                        // `.fill` rather than `.fit`: YouTube's `hqdefault` thumbnails are 4:3 with the
                        // frame letterboxed inside them, and fitting a 4:3 image into our 16:9 area would
                        // show those baked-in black bars plus fresh pillarboxing. Filling crops them off.
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// True while the player has nothing of its own to draw. `.failed` is included so the error
    /// message reads over the thumbnail instead of over black.
    private var coversPlayerSurface: Bool {
        if isAudioOnly { return true }
        switch state {
        case .resolving, .buffering, .downloading, .failed:
            return true
        case .idle, .readyToPlay:
            return false
        }
    }
}
