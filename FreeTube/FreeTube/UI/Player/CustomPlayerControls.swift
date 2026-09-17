import SwiftUI

@available(iOS 17.0, *)
struct CustomPlayerControls: View {
    let isVisible: Bool
    let isSeekPreviewActive: Bool
    let isPlaying: Bool
    let isWaitingForPlayback: Bool
    let pendingAutoplay: Bool
    let hasEnded: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let isLive: Bool
    let sponsorSegments: [SponsorBlockSegment]
    let chapters: [VideoChapter]
    let hasPrevious: Bool
    let hasNext: Bool
    let videoTitle: String
    let channelName: String
    let showsCollapseButton: Bool
    let additionalTopControls: AnyView
    let fullscreenControl: AnyView
    let bottomTimelinePadding: CGFloat
    let onTogglePlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onSeekPreviewChanged: (TimeInterval?) -> Void
    let onShowChapters: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(isVisible ? 0.28 : 0)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    if showsCollapseButton {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.down")
                                .playerTopControl()
                        }
                        Spacer()
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(videoTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if !channelName.isEmpty {
                                Text(channelName)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                    additionalTopControls
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .opacity(isVisible ? 1 : 0)

                Spacer()

                HStack(spacing: 42) {
                    Button(action: onPrevious) {
                        Image(systemName: "backward.end.fill").playerCenterControl()
                    }
                    .disabled(!hasPrevious)
                    Button(action: onTogglePlayPause) {
                        centerTransportLabel
                    }
                    .accessibilityLabel(centerTransportAccessibilityLabel)
                    Button(action: onNext) {
                        Image(systemName: "forward.end.fill").playerCenterControl()
                    }
                    .disabled(!hasNext)
                }
                .buttonStyle(.plain)
                .opacity(isVisible ? 1 : 0)

                Spacer()

                HStack(alignment: .bottom, spacing: 8) {
                    SponsorBlockTimeline(
                        elapsed: elapsed,
                        duration: duration,
                        isLive: isLive,
                        segments: sponsorSegments,
                        chapters: chapters,
                        onSeek: onSeek,
                        onPreviewChanged: onSeekPreviewChanged,
                        onShowChapters: onShowChapters
                    )
                    .frame(maxWidth: .infinity)
                    fullscreenControl
                        .opacity(isVisible ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, bottomTimelinePadding)
                .opacity(isVisible || isSeekPreviewActive ? 1 : 0)
            }
        }
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible && !isSeekPreviewActive)
        .animation(.easeInOut(duration: 0.24), value: isVisible)
        .animation(.easeInOut(duration: 0.12), value: isSeekPreviewActive)
    }

    private var transportIcon: PlayerTransportIcon {
        PlayerTransportIcon.resolve(
            hasEnded: hasEnded,
            isPlaying: isPlaying,
            pendingAutoplay: pendingAutoplay,
            isWaitingForPlayback: isWaitingForPlayback
        )
    }

    @ViewBuilder
    private var centerTransportLabel: some View {
        switch transportIcon {
        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .controlSize(.large)
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
        case .play, .pause, .replay:
            Image(systemName: centerTransportSystemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
        }
    }

    private var centerTransportSystemImage: String {
        switch transportIcon {
        case .replay: return "arrow.counterclockwise"
        case .pause: return "pause.fill"
        case .play, .loading: return "play.fill"
        }
    }

    private var centerTransportAccessibilityLabel: String {
        switch transportIcon {
        case .loading: return String(localized: "Loading")
        case .replay: return String(localized: "Replay")
        case .pause: return String(localized: "Pause")
        case .play: return String(localized: "Play")
        }
    }

}

extension Image {
    func playerTopControl() -> some View {
        font(.body.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
    }

    func playerCenterControl() -> some View {
        font(.system(size: 27, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
    }
}
