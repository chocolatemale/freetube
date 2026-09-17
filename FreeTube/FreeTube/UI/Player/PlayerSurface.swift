import SwiftUI
import AVKit

/// AVPlayerViewController remains the video/PiP engine. Its native playback chrome is hidden in
/// favour of `CustomPlayerControls`, while the underlying controller still owns rendering and PiP.
@available(iOS 17.0, *)
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let pipDismissalRequest: Int
    var onSeekRelative: (TimeInterval) -> Void
    var onSeekAbsolute: (TimeInterval) -> Void
    var onSeekPreview: (TimeInterval?) -> Void
    var onTogglePlayback: () -> Void
    var onToggleControls: () -> Void
    var onRestoreFromPictureInPicture: () -> Void
    var showsControls: Bool = false
    var entersPiPAutomatically: Bool = true

    func makeCoordinator() -> PlayerGestureCoordinator {
        PlayerGestureCoordinator(
            player: player,
            pipDismissalRequest: pipDismissalRequest,
            onSeekRelative: onSeekRelative,
            onSeekAbsolute: onSeekAbsolute,
            onSeekPreview: onSeekPreview,
            onTogglePlayback: onTogglePlayback,
            onToggleControls: onToggleControls,
            onRestoreFromPictureInPicture: onRestoreFromPictureInPicture
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
        controller.allowsPictureInPicturePlayback = true
        controller.allowsVideoFrameAnalysis = false
        // Force the hierarchy to load before asking for `contentOverlayView`.
        _ = controller.view
        context.coordinator.install(on: controller)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.showsPlaybackControls = showsControls
        controller.canStartPictureInPictureAutomaticallyFromInline = entersPiPAutomatically
        controller.allowsVideoFrameAnalysis = false
        context.coordinator.dismissPiPIfRequested(
            on: controller,
            request: pipDismissalRequest
        )
        context.coordinator.update(
            player: player,
            onSeekRelative: onSeekRelative,
            onSeekAbsolute: onSeekAbsolute,
            onSeekPreview: onSeekPreview,
            onTogglePlayback: onTogglePlayback,
            onToggleControls: onToggleControls,
            onRestoreFromPictureInPicture: onRestoreFromPictureInPicture
        )
        context.coordinator.install(on: controller)
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: PlayerGestureCoordinator
    ) {
        coordinator.uninstall()
        controller.delegate = nil
    }
}
