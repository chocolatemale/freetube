import SwiftUI
import UIKit

import Kingfisher

/// Expanded player content presented by `LNPopupUI` when the popup bar is opened. The popup chrome
/// (close button) is provided by the library — this view renders the surface, transport controls,
/// metadata, plus independently collapsible Up Next and Comments sections below.
@available(iOS 17.0, *)
struct FullScreenPlayer: View {
    @Environment(PlayerStateManager.self) private var player
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var downloads = DownloadManager.shared

    /// Keep recommendation rows out of the render tree until the user asks to inspect them.
    @State private var isQueueExpanded = false
    @State private var upNextVisibleLimit = 5
    @State private var isPlaylistExpanded = true
    @State private var playlistItemsBefore = 20
    @State private var playlistItemsAfter = 20
    /// Async-loaded description / details for the currently-playing video. Fetched on demand when
    /// the user taps "More" under the channel row.
    @State private var details: VideoInfo?
    /// Are we currently fetching `details`? Drives the spinner in the description area.
    @State private var isLoadingDetails = false
    @State private var detailsLoadFailed = false
    /// True when the user has expanded the description block — shows full text instead of a
    /// truncated preview, and tries to load extended details (tags etc.) if not yet loaded.
    @State private var isDetailsExpanded = false
    /// File URL the user wants to hand off to another app via the system "Open in…" share sheet.
    /// Non-nil → present the activity controller; tapped row sets this, sheet dismissal clears it.
    @State private var shareFileURL: URL?
    @State private var saveToPlaylistVideo: Video?
    @State private var isSavedToPersonalPlaylist = false
    @State private var downloadError: ErrorState?
    /// Currently-pushed channel (nil = panel mode). When non-nil, the lower section swaps the
    /// metadata + comments/queue panel for a NavigationStack rooted at `ChannelScreen`. Keeping
    /// the NavigationStack **conditionally mounted** is what makes the panel-mode background
    /// match the transport row: SwiftUI's NavigationStack container paints opaque under its
    /// content, so any thinMaterial inside it stacks on top of an opaque layer and reads darker
    /// than the rest of the popup. With the stack absent in panel mode, the outer VStack's
    /// thinMaterial paints through cleanly.
    @State private var pushedChannel: ChannelPresentation?
    /// Path for deeper pushes inside the channel flow (e.g. ChannelScreen → ChannelTabScreen).
    /// Only meaningful while `pushedChannel != nil`.
    @State private var channelPath = NavigationPath()
    @State private var playerControlsVisible = true
    @State private var gestureSeekPreview: TimeInterval?
    @State private var scrubberSeekPreview: TimeInterval?
    @State private var panelScrollOffset: CGFloat = 0
    @State private var panelScrollGestureActive = false
    @State private var controlsHideTask: Task<Void, Never>?
    /// Portrait videos use an in-place fullscreen mode rather than rotating a tall source into a
    /// short landscape viewport. The same fullscreen control toggles this state back off.
    @State private var portraitVideoFullscreen = false
    @AppStorage("autoplayNext") private var autoplayNext = true
    @AppStorage("prefetchVideoDetails") private var prefetchVideoDetails = true
    @AppStorage("showComments") private var showComments = true
    @AppStorage("showUpNext") private var showUpNext = true
    @AppStorage("upNextInitialCount") private var upNextInitialCount = 5
    @AppStorage("oledPlayerBackground") private var oledPlayerBackground = false
    @AppStorage("playerTopControlOrder") private var playerTopControlOrderRaw = PlayerTopControl.encodeOrder(PlayerTopControl.defaultOrder)
    @AppStorage("hiddenPlayerTopControls") private var hiddenPlayerTopControlsRaw = ""

    /// Hashable wrapper so `.navigationDestination(for:)` can match the channel id and push
    /// `ChannelScreen` onto `channelPath`.
    struct ChannelPresentation: Identifiable, Hashable {
        let id: String
    }

    var body: some View {
        // Single dark-blur material under EVERYTHING — status bar inset, video chrome, transport,
        // comments, queue. Removing per-section backgrounds and using one full-screen material lets
        // the popup read as one continuous translucent surface instead of three stacked tones.
        //
        // The outer GeometryReader provides a stable viewport for both the display-correct
        // expanded ratio and the compact 16:9 ratio. Their difference becomes the first part of
        // the lower panel's scroll range, allowing a tall player to behave as a collapsible header.
        GeometryReader { proxy in
            let isLandscape = verticalSizeClass == .compact
            let usesPortraitFullscreen = portraitVideoFullscreen && isPortraitVideo && !isLandscape
            let chapterPanelWidth: CGFloat = isLandscape && player.chapterListPresented
                ? min(360, proxy.size.width * 0.38)
                : 0
            let surfaceWidth = proxy.size.width - chapterPanelWidth
            let compactSurfaceHeight = surfaceWidth * 9 / 16
            let expandedSurfaceHeight = usesPortraitFullscreen
                ? proxy.size.height
                : expandedPlayerSurfaceHeight(
                    width: surfaceWidth,
                    viewportHeight: proxy.size.height
                )
            let collapseRange = usesPortraitFullscreen
                ? 0
                : max(0, expandedSurfaceHeight - compactSurfaceHeight)
            let consumedCollapse = min(max(panelScrollOffset, 0), collapseRange)
            let surfaceHeight = expandedSurfaceHeight - consumedCollapse

            ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                // Pinning the ZStack to width × width*9/16 keeps the surface a stable height
                // across .resolving → .downloading → .readyToPlay (the underlying
                // AVPlayerViewController has zero intrinsic size while loading; the explicit
                // frame here is what stops the layout from jumping when the user taps a queue
                // item).
                // Layer order is load-bearing. `AVPlayerViewController` paints an opaque black
                // background, so the thumbnail has to sit *above* `PlayerSurface` to be visible at
                // all — it hides itself once `loadState` reaches `.readyToPlay`. The `.animation`
                // on the container is what turns that hand-off into a crossfade instead of a cut.
                ZStack {
                    Color.black
                    PlayerSurface(
                        player: player.player,
                        pipDismissalRequest: player.pipDismissalRequest,
                        onSeekRelative: { seconds in
                            player.seekRelative(by: seconds)
                        },
                        onSeekAbsolute: { seconds in
                            player.seek(to: seconds)
                        },
                        onSeekPreview: { seconds in
                            gestureSeekPreview = seconds
                        },
                        onTogglePlayback: {
                            player.togglePlayPause()
                        },
                        onToggleControls: { togglePlayerControls() },
                        onRestoreFromPictureInPicture: {
                            player.miniPlayerVisible = true
                            player.fullScreenPresented = true
                            player.requestInlinePlaybackRestoration()
                        }
                    )
                    PlayerArtworkBackdrop(artwork: player.currentArtwork, state: player.loadState, isAudioOnly: player.isAudioOnlySession)
                    DownloadProgressOverlay(state: player.loadState)
                    CustomPlayerControls(
                        isVisible: playerControlsVisible,
                        isSeekPreviewActive: gestureSeekPreview != nil || scrubberSeekPreview != nil,
                        isPlaying: player.isPlaying,
                        hasEnded: player.hasEnded,
                        elapsed: scrubberSeekPreview ?? gestureSeekPreview ?? player.elapsed,
                        duration: player.duration,
                        isLive: player.currentVideo?.isLive == true,
                        sponsorSegments: player.sponsorBlockSegments,
                        chapters: player.chapters,
                        hasPrevious: hasPrevious,
                        hasNext: hasNext,
                        videoTitle: player.currentVideo?.title ?? "",
                        channelName: player.currentVideo?.channelName ?? "",
                        showsCollapseButton: !isLandscape && !usesPortraitFullscreen,
                        additionalTopControls: AnyView(
                            HStack(spacing: 0) {
                                ForEach(visiblePlayerTopControls) { control in
                                    playerTopControl(control)
                                }
                            }
                            .buttonStyle(.plain)
                        ),
                        bottomTimelinePadding: timelineBottomPadding(
                            in: CGSize(width: surfaceWidth, height: proxy.size.height)
                        ),
                        onTogglePlayPause: {
                            player.togglePlayPause()
                            showPlayerControls()
                        },
                        onSeek: {
                            player.seek(to: $0)
                            showPlayerControls()
                        },
                        onSeekPreviewChanged: { seconds in
                            scrubberSeekPreview = seconds
                        },
                        onShowChapters: {
                            guard !player.chapters.isEmpty else { return }
                            withAnimation(.snappy(duration: 0.28)) {
                                player.chapterListPresented.toggle()
                            }
                            showPlayerControls()
                        },
                        onPrevious: {
                            player.playPrevious()
                            showPlayerControls()
                        },
                        onNext: {
                            player.playNext()
                            showPlayerControls()
                        },
                        onCollapse: {
                            @Bindable var p = player
                            p.chapterListPresented = false
                            p.fullScreenPresented = false
                        }
                    )
                    if let previewTime = scrubberSeekPreview,
                       let tile = player.storyboard?.tile(
                           at: previewTime,
                           duration: player.duration,
                           maximumWidth: 320,
                           maximumHeight: 180
                       ) {
                        StoryboardPreview(tile: tile)
                            .position(
                                x: storyboardPreviewX(
                                    for: previewTime,
                                    duration: player.duration,
                                    surfaceWidth: surfaceWidth
                                ),
                                y: max(
                                    58,
                                    surfaceHeight
                                        - timelineBottomPadding(
                                            in: CGSize(width: surfaceWidth, height: proxy.size.height)
                                        )
                                        - 68
                                )
                            )
                            .allowsHitTesting(false)
                    }
                    if let notice = player.sponsorBlockNotice {
                        SponsorBlockSkipOverlay(
                            notice: notice,
                            onUndo: { player.undoSponsorBlockSkip() },
                            onSkip: { player.confirmSponsorBlockSkip() },
                            onDismiss: { player.dismissSponsorBlockNotice() },
                            bottomPadding: timelineBottomPadding(
                                in: CGSize(width: surfaceWidth, height: proxy.size.height)
                            ) + 46
                        )
                    }
                }
                .frame(width: surfaceWidth, height: surfaceHeight)
                .animation(.easeOut(duration: 0.2), value: player.loadState)
                .onAppear { showPlayerControls() }
                .onDisappear { controlsHideTask?.cancel() }
                .onChange(of: player.currentVideo?.id) { _, _ in
                    gestureSeekPreview = nil
                    scrubberSeekPreview = nil
                    player.chapterListPresented = false
                    portraitVideoFullscreen = false
                    panelScrollOffset = 0
                    player.playerPanelAtTop = true
                    player.playerPanelGestureStartedAwayFromTop = false
                    showPlayerControls()
                }
                .onChange(of: player.loadState, initial: true) { _, state in
                    if state == .readyToPlay, player.isPlaying {
                        // The initial onAppear/current-video callbacks run while resolution is
                        // still pending, when showPlayerControls cannot schedule its hide timer.
                        // Readiness is the first reliable point at which playback can own it.
                        showPlayerControls()
                    }
                    guard state == .readyToPlay,
                          prefetchVideoDetails,
                          let video = player.currentVideo else { return }
                    loadDetailsIfNeeded(for: video)
                }
            // Pull-down-to-dismiss starting from the video surface.
            //
            // `AVPlayerViewController`'s internal `UIPanGestureRecognizer`s (scrubber, system
            // controls) consume touches before they can reach LNPopupUI's outer pan, so the
            // the popup host cannot reliably detect a gesture starting here. This explicit
            // simultaneous gesture keeps AVPlayerViewController's controls working while allowing
            // a pull begun on the video itself to collapse the popup.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global)
                    .onEnded { value in
                        guard !usesPortraitFullscreen else { return }
                        let predicted = value.predictedEndTranslation
                        let verticalIntent = abs(predicted.height) > abs(predicted.width) * 1.15
                        guard verticalIntent else { return }
                        let mostlyDown = value.translation.height > 90
                            && abs(value.translation.width) < value.translation.height
                        let fastFlick = predicted.height > 180
                        if mostlyDown || fastFlick {
                            @Bindable var p = player
                            p.fullScreenPresented = false
                        }
                    }
            )

            if let video = player.currentVideo, !usesPortraitFullscreen {
                // **Two render modes for the lower section, picked by `pushedChannel`:**
                //
                // 1. **Panel mode (default, channel == nil):** plain ScrollView, NO
                //    NavigationStack. The outer VStack's `.background { thinMaterial }` paints
                //    behind it directly — exactly the same backdrop the transport row above
                //    shows. This is what makes the visual treatment consistent.
                //
                // 2. **Channel-pushed mode (channel != nil):** NavigationStack rooted at
                //    `ChannelScreen`, with its own thinMaterial inside since the stack's UIKit
                //    container paints opaque. Channel's own internal NavigationLinks (to
                //    ChannelTabScreen / PlaylistScreen) push further into this stack.
                //
                // The previous version kept the NavigationStack mounted in both modes — that
                // forced us to paint an inner thinMaterial under the comments/queue panel,
                // which stacked on top of the stack's opaque container and read noticeably
                // darker than the transport row. Mounting the stack only when needed fixes it.
                Group {
                    if let channel = pushedChannel {
                        channelStack(channel)
                    } else {
                        panel(
                            video,
                            collapseRange: collapseRange,
                            minimumContentHeight: max(
                                0,
                                proxy.size.height - compactSurfaceHeight + collapseRange
                            )
                        )
                    }
                }
                // Reset description state, (best-effort) prefetch the snippet, AND pop any
                // pushed channel screen whenever the user picks a new video — otherwise tapping
                // the next video in the queue would leave a stale channel push on screen.
                .onChange(of: video.id) { _, _ in
                    details = nil
                    isDetailsExpanded = false
                    detailsLoadFailed = false
                    pushedChannel = nil
                    channelPath = NavigationPath()
                    prefetchDescriptionIfAvailable(for: video)
                }
                // Keep the previous landscape video/sidebar geometry. Only constrain the lower
                // metadata column so its title and rows cannot extend underneath Chapters.
                .frame(width: surfaceWidth, alignment: .leading)
            }
            }
            .frame(width: proxy.size.width, alignment: .leading)

            if player.chapterListPresented, !player.chapters.isEmpty, !usesPortraitFullscreen {
                ChapterListPanel(
                    chapters: player.chapters,
                    elapsed: player.elapsed,
                    isLandscape: isLandscape,
                    usesOLEDBackground: oledPlayerBackground,
                    onSeek: { target in
                        player.seek(to: target)
                        showPlayerControls()
                    },
                    onDismiss: {
                        withAnimation(.snappy(duration: 0.28)) {
                            player.chapterListPresented = false
                        }
                    }
                )
                .frame(
                    width: isLandscape ? chapterPanelWidth : proxy.size.width,
                    height: isLandscape ? proxy.size.height : max(0, proxy.size.height - surfaceHeight)
                )
                .offset(y: isLandscape ? 0 : surfaceHeight)
                // Moving the landscape material sidebar while simultaneously widening the player
                // leaves a stale strip at the trailing edge for one render pass. Remove it
                // atomically and let the underlying column resize; portrait retains its sheet
                // transition because its geometry does not change horizontally.
                .transition(isLandscape ? .identity : .move(edge: .bottom))
                .zIndex(5)
            }
            }
        // One continuous material under EVERYTHING, including the top safe-area inset (status bar).
        // VStack content still respects safe area; only the material extends behind the inset.
        .background {
            if oledPlayerBackground {
                Color.black.ignoresSafeArea()
            } else {
                Rectangle()
                    .fill(.thinMaterial)
                    .ignoresSafeArea()
            }
        }
        // Ensure the system status bar stays visible and gets light-content (white) glyphs against
        // the dark material. LNPopupUI's `LNPopupContentHostingController` is a UIHostingController
        // subclass that doesn't override status bar style, so SwiftUI's colorScheme drives it.
        .preferredColorScheme(.dark)
        .statusBarHidden(portraitFullscreenActive)
        // Presents UIActivityViewController for the "Open in…" menu action. Wrapping shareFileURL
        // in a `Binding<Bool>` that flips when the URL is set/cleared so the sheet lifecycle
        // matches the user's intent.
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ActivityShareSheet(activityItems: [url])
            }
        }
        .sheet(item: $saveToPlaylistVideo) { video in
            AddToPlaylistSheet(video: video)
        }
        .task(id: player.currentVideo?.id) {
            await refreshPersonalPlaylistMembership()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localPlaylistsDidChange)) { _ in
            Task { await refreshPersonalPlaylistMembership() }
        }
        .errorToast($downloadError)
        .onChange(of: player.fullScreenPresented) { _, isPresented in
            if !isPresented {
                portraitVideoFullscreen = false
            }
        }

        // Make the VStack fill the GeometryReader's bounds. Without this, the VStack only
        // claims the natural content height (video + panel intrinsic
        // height) and the `.background { thinMaterial }` doesn't extend below that. On
        // smaller-than-content windows (Mac shrunk) this is invisible; on larger ones
        // (Mac maximized) you'd see an unfilled gap below the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Lower section: panel vs channel-push

    /// The video remains full-width in landscape. When its 16:9 height exceeds a short phone
    /// viewport, lift only the timeline by that overflow so the picture geometry does not change.
    private func timelineBottomPadding(in availableSize: CGSize) -> CGFloat {
        let aspectHeight = availableSize.width * 9 / 16
        guard verticalSizeClass == .compact else { return 8 }
        return max(22, aspectHeight - availableSize.height + 16)
    }

    /// Uses AVPlayer's display-correct dimensions for portrait/tall media. Tall videos start at
    /// their natural ratio (bounded so some feed remains reachable), then smoothly compress toward
    /// the familiar 16:9 player as the lower panel scrolls, matching YouTube's expanding header.
    private func expandedPlayerSurfaceHeight(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let compactHeight = width * 9 / 16
        let size = player.videoPresentationSize
        guard verticalSizeClass != .compact,
              size.width > 0, size.height > 0 else { return compactHeight }
        let naturalHeight = width * size.height / size.width
        return min(max(naturalHeight, compactHeight), viewportHeight * 0.72)
    }

    /// Tracks the timeline thumb while keeping the 116pt-wide preview plus edge clearance
    /// wholly inside the player surface at both ends of the video.
    private func storyboardPreviewX(
        for time: TimeInterval,
        duration: TimeInterval,
        surfaceWidth: CGFloat
    ) -> CGFloat {
        guard duration.isFinite, duration > 0, time.isFinite, surfaceWidth > 0 else {
            return surfaceWidth / 2
        }
        let fraction = min(max(time / duration, 0), 1)
        let trackX = 12 + (surfaceWidth - 24) * CGFloat(fraction)
        let minimumCenterX: CGFloat = 66
        guard surfaceWidth >= minimumCenterX * 2 else { return surfaceWidth / 2 }
        return min(max(trackX, minimumCenterX), surfaceWidth - minimumCenterX)
    }

    @ViewBuilder
    private var fullscreenButton: some View {
        Button {
            if isPortraitVideo {
                withAnimation(.smooth(duration: 0.3)) {
                    portraitVideoFullscreen.toggle()
                    player.chapterListPresented = false
                }
                if portraitVideoFullscreen {
                    requestPlayerOrientation(.portrait)
                }
            } else {
                requestPlayerOrientation(verticalSizeClass == .compact ? .portrait : .landscapeRight)
            }
            showPlayerControls()
        } label: {
            Image(systemName: verticalSizeClass == .compact || portraitFullscreenActive
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
        }
        .accessibilityLabel(
            verticalSizeClass == .compact || portraitFullscreenActive
                ? "Exit fullscreen"
                : "Enter fullscreen"
        )
    }

    private var portraitFullscreenActive: Bool {
        portraitVideoFullscreen && isPortraitVideo && verticalSizeClass != .compact
    }

    private var isPortraitVideo: Bool {
        let size = player.videoPresentationSize
        if size.width > 0, size.height > 0 { return size.height > size.width }
        return player.currentVideo?.isShort == true
    }

    private func requestPlayerOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        UIViewController.attemptRotationToDeviceOrientation()
    }

    /// Default panel mode. No NavigationStack wrapping — the outer popup's `.thinMaterial`
    /// shows through directly behind metadata, Up Next, and Comments.
    @ViewBuilder
    private func panel(
        _ video: Video,
        collapseRange: CGFloat,
        minimumContentHeight: CGFloat
    ) -> some View {
        if #available(iOS 18.0, *) {
            panelScrollView(
                video,
                collapseRange: collapseRange,
                minimumContentHeight: minimumContentHeight
            )
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, offset in
                    panelScrollOffset = offset
                    player.playerPanelAtTop = offset <= 0.5
                }
        } else {
            panelScrollView(
                video,
                collapseRange: collapseRange,
                minimumContentHeight: minimumContentHeight
            )
                .coordinateSpace(name: "playerPanelScroll")
                .onPreferenceChange(PlayerPanelScrollOffsetKey.self) { offset in
                    panelScrollOffset = offset
                    player.playerPanelAtTop = offset <= 0.5
                }
        }
    }

    private func panelScrollView(
        _ video: Video,
        collapseRange: CGFloat,
        minimumContentHeight: CGFloat
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear
                    // Keep the geometry probe alive so it reliably emits scroll preferences.
                    .frame(height: 1)
                    .reportPlayerPanelScrollOffset()
                metadata(video)
                detailsSection(video: video)
                if player.activePlaylist != nil {
                    playlistPanel
                }
                if showUpNext {
                    queuePanel
                }
                if showComments {
                    CommentsSection(
                        videoID: video.id,
                        countText: details?.commentsCountText ?? player.commentsCountText
                    )
                        .id(video.id)
                }
            }
            .padding(.vertical)
            // While the header is collapsing, counteract the ScrollView's own content movement.
            // Use real padding rather than a visual offset: an offset does not enlarge the
            // ScrollView's measured content and made the final comments unreachable by exactly
            // this compensation distance.
            .padding(.top, min(max(panelScrollOffset, 0), collapseRange))
            // Preserve enough scroll extent to consume the complete header collapse even when
            // comments and Up Next are both collapsed and the natural feed is very short.
            .frame(minHeight: minimumContentHeight, alignment: .top)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    guard !panelScrollGestureActive else { return }
                    panelScrollGestureActive = true
                    player.playerPanelGestureStartedAwayFromTop = panelScrollOffset > 0.5
                }
                .onEnded { _ in
                    panelScrollGestureActive = false
                    player.playerPanelGestureStartedAwayFromTop = false
                }
        )
        .scrollContentBackground(.hidden)
    }

    /// NavigationStack rooted at `ChannelScreen`. Mounted only when `pushedChannel != nil`.
    /// Internal `NavigationLink`s inside `ChannelScreen` push onto `channelPath`; popping the
    /// last item via our back button returns to panel mode.
    @ViewBuilder
    private func channelStack(_ root: ChannelPresentation) -> some View {
        NavigationStack(path: $channelPath) {
            channelDestination(root, isRoot: true)
                .navigationDestination(for: ChannelPresentation.self) { channel in
                    channelDestination(channel, isRoot: false)
                }
        }
    }

    /// Single channel destination — used for both the root channel (pushed from the player) and
    /// any further pushes via NavigationLink. The back button pops `channelPath` when there's
    /// something on it, otherwise clears `pushedChannel` to return to panel mode.
    @ViewBuilder
    private func channelDestination(_ channel: ChannelPresentation, isRoot: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ChannelScreen(channelID: channel.id)
                .toolbar(.hidden, for: .navigationBar)
                // Solid black, matching the playlist push inside this same NavigationStack.
                // We deliberately don't use `.thinMaterial` here — pushed destinations inside
                // the popup body use opaque black for visual consistency with PlaylistScreen,
                // while the panel-mode comments/queue area keeps the popup's outer thinMaterial.
                .background {
                    Color.black.ignoresSafeArea()
                }

            Button {
                if !channelPath.isEmpty {
                    channelPath.removeLast()
                } else {
                    pushedChannel = nil
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .padding(.top, 8)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadata(_ video: Video) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDetailsExpanded.toggle()
                }
                if isDetailsExpanded {
                    loadDetailsIfNeeded(for: video)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(video.title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: isDetailsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let statsRow = detailsStatsRow(video: video)
            if video.isLive || !statsRow.isEmpty {
                HStack(spacing: 7) {
                    if video.isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if !statsRow.isEmpty {
                        Text(statsRow)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Tapping anywhere on the channel row pushes the channel detail screen onto the
            // popup's internal NavigationStack — banner, subscribe button, latest videos,
            // shorts, playlists. Pushing (rather than presenting) keeps the video surface and
            // transport controls visible at the top; only the panel area below is replaced.
            HStack(spacing: 8) {
                if !video.channelID.isEmpty {
                    Button {
                        @Bindable var p = player
                        p.fullScreenPresented = false
                        let channelID = video.channelID
                        Task { @MainActor in
                            // Let LNPopupUI begin its collapse before presenting a new full-screen
                            // controller; presenting both in the same transaction is ignored by UIKit.
                            try? await Task.sleep(for: .milliseconds(180))
                            NotificationCenter.default.post(
                                name: .freetubeOpenChannel,
                                object: channelID
                            )
                        }
                    } label: {
                        channelRow(video)
                    }
                    .buttonStyle(.plain)
                } else {
                    channelRow(video)
                }
                Spacer(minLength: 4)
                playerActions(video)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func channelRow(_ video: Video) -> some View {
        HStack(spacing: 12) {
            KFImage(video.channelThumbnailURL)
                .thumbnail(size: CGSize(width: 32, height: 32)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            Text(video.channelName)
                .font(.subheadline)
                .lineLimit(1)
        }
    }

    // MARK: - Description / details (between channel row and comments)

    /// Shows the video description in a YouTube-like collapsed-by-default block. Tapping the video
    /// title expands it and lazily fetches the full details payload.
    @ViewBuilder
    private func detailsSection(video: Video) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDetailsExpanded {
                expandedDetailsBody(video: video)
            } else {
                collapsedDetailsBody(video: video)
            }
        }
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.2), value: isDetailsExpanded)
    }

    @ViewBuilder
    private func collapsedDetailsBody(video: Video) -> some View {
        if let snippet = inlineDescriptionSnippet(video: video) {
            Text(snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func expandedDetailsBody(video: Video) -> some View {
        // Full description text (from the loaded details, falling back to the search-result snippet).
        if let text = availableDescription(video: video) {
            RichDescriptionText(
                parts: details?.descriptionParts ?? [],
                fallback: text,
                onSeek: { player.seek(to: $0) }
            )
                .font(.subheadline)
                .foregroundStyle(.primary)
        } else if isLoadingDetails {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading details…").font(.caption).foregroundStyle(.secondary)
            }
        } else if detailsLoadFailed {
            HStack(spacing: 8) {
                Text("Description unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    details = nil
                    loadDetailsIfNeeded(for: video)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }

        // Like count if we got it from the details payload.
        if let likes = details?.likeCount, likes > 0 {
            Text("\(formatCount(likes)) likes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }

    /// Picks the description text to render in the 2-line collapsed preview. Prefer the loaded
    /// details (more complete), fall back to the search-result snippet.
    private func inlineDescriptionSnippet(video: Video) -> String? {
        availableDescription(video: video)
    }

    private func availableDescription(video: Video) -> String? {
        if let fetched = details?.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fetched.isEmpty {
            return fetched
        }
        if let snippet = video.descriptionSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
           !snippet.isEmpty {
            return snippet
        }
        return nil
    }

    /// `42K views • Uploaded 3 days ago`, omitting any pieces we don't have.
    private func detailsStatsRow(video: Video) -> String {
        var parts: [String] = []
        if let viewsText = details?.viewCountText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !viewsText.isEmpty {
            parts.append(viewsText)
        } else if let views = video.viewCount, views > 0 {
            parts.append("\(formatCount(views)) views")
        }
        if let uploadDateText = details?.uploadDateText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !uploadDateText.isEmpty {
            parts.append("Uploaded \(uploadDateText)")
        } else if let published = video.publishedAt {
            parts.append("Uploaded \(published.formatted(date: .abbreviated, time: .omitted))")
        } else if let relative = video.publishedRelative, !relative.isEmpty {
            parts.append("Uploaded \(relative)")
        }
        return parts.joined(separator: " • ")
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Best-effort: if `descriptionSnippet` is already on the `Video` (from search/home), we have
    /// something to show without hitting the network. Don't preemptively fetch the full details —
    /// the user might never tap "More".
    private func prefetchDescriptionIfAvailable(for video: Video) {
        // Intentional no-op. The fetch happens on the user's first "More" tap.
        _ = video
    }

    /// Lazy fetch invoked when the user expands the description. One `VideoService.fetchMoreInfo`
    /// call per video; subsequent expansions reuse the cached result in `details`.
    private func loadDetailsIfNeeded(for video: Video) {
        guard details == nil, !isLoadingDetails else { return }
        isLoadingDetails = true
        detailsLoadFailed = false
        Task { [videoID = video.id] in
            defer { Task { @MainActor in isLoadingDetails = false } }
            do {
                let info = try await VideoContentPrefetchStore.shared.fetchDetails(videoID: videoID)
                await MainActor.run {
                    // Drop the result if the user switched videos before this returned.
                    guard player.currentVideo?.id == videoID else { return }
                    details = info
                    player.installVideoDetails(info, for: videoID)
                    let fetched = info.descriptionText?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = video.descriptionSnippet?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    detailsLoadFailed = (fetched?.isEmpty ?? true) && (snippet?.isEmpty ?? true)
                }
            } catch {
                await MainActor.run {
                    guard player.currentVideo?.id == videoID else { return }
                    detailsLoadFailed = true
                }
            }
        }
    }

    // MARK: - Player actions

    @ViewBuilder
    private func playerActions(_ video: Video) -> some View {
        HStack(spacing: 4) {
            Button {
                saveToPlaylistVideo = video
            } label: {
                Image(systemName: isSavedToPersonalPlaylist ? "bookmark.fill" : "bookmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Save to playlist")

            Menu {
                if let url = watchURL(video) {
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Link(destination: url) {
                        Label("Open in browser", systemImage: "safari")
                    }
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                    } label: {
                        Label("Copy URL", systemImage: "link")
                    }
                }
                Button {
                    if let url = watchURLAtCurrentTime(video) {
                        UIPasteboard.general.string = url.absoluteString
                    }
                } label: {
                    Label("Copy URL at current time", systemImage: "clock")
                }
                if let localFile = downloads.localFile(for: video.id) {
                    Button {
                        shareFileURL = localFile
                    } label: {
                        Label("Share downloaded file…", systemImage: "doc")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Share")

            Button {
                startDownload(video)
            } label: {
                downloadButtonLabel(for: video)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(isDownloadActive(for: video) || downloads.localFile(for: video.id) != nil)
            .accessibilityLabel(downloadAccessibilityLabel(for: video))
        }
    }

    private func refreshPersonalPlaylistMembership() async {
        guard let videoID = player.currentVideo?.id else {
            isSavedToPersonalPlaylist = false
            return
        }
        let isSaved = await LocalPlaylistService().isInPersonalPlaylist(videoID: videoID)
        guard player.currentVideo?.id == videoID else { return }
        isSavedToPersonalPlaylist = isSaved
    }

    @ViewBuilder
    private func downloadButtonLabel(for video: Video) -> some View {
        if downloads.localFile(for: video.id) != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
        } else if isDownloadActive(for: video) {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.title3.weight(.semibold))
        }
    }

    private func downloadAccessibilityLabel(for video: Video) -> String {
        if downloads.localFile(for: video.id) != nil { return "Downloaded" }
        if isDownloadActive(for: video) { return "Downloading" }
        return "Download"
    }

    private func isDownloadActive(for video: Video) -> Bool {
        downloads.activeTasks.contains { snapshot in
            guard snapshot.videoID == video.id else { return false }
            switch snapshot.state {
            case .queued, .downloading, .paused: return true
            case .completed, .failed: return false
            }
        }
    }

    private func startDownload(_ video: Video) {
        let quality = UserPreferences().preferredQuality
        Task {
            do {
                _ = try await downloads.ensureDownloaded(video: video, quality: quality)
            } catch {
                downloadError = ErrorState(from: error)
            }
        }
    }

    // MARK: - Transport

    private func togglePlayerControls() {
        playerControlsVisible ? hidePlayerControls() : showPlayerControls()
    }

    private func showPlayerControls() {
        controlsHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { playerControlsVisible = true }
        guard player.isPlaying else { return }
        controlsHideTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            hidePlayerControls()
        }
    }

    private func hidePlayerControls() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        withAnimation(.easeIn(duration: 0.18)) { playerControlsVisible = false }
    }

    private var hasPrevious: Bool {
        player.canPlayPrevious
    }

    private var hasNext: Bool {
        player.canPlayNext
    }

    private var visiblePlayerTopControls: [PlayerTopControl] {
        let hidden = PlayerTopControl.decodeHidden(hiddenPlayerTopControlsRaw)
        return PlayerTopControl.decodeOrder(playerTopControlOrderRaw).filter { !hidden.contains($0) }
    }

    @ViewBuilder
    private func playerTopControl(_ control: PlayerTopControl) -> some View {
        switch control {
        case .speed:
            speedPlayerMenu
        case .loop:
            loopPlayerButton
        case .mute:
            mutePlayerButton
        case .fullscreen:
            fullscreenButton
        case .autoplay:
            autoplayPlayerButton
        }
    }

    @ViewBuilder
    private var speedPlayerMenu: some View {
        Menu {
            ForEach([0.5, 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button {
                    player.setPlaybackRate(rate)
                    showPlayerControls()
                } label: {
                    if abs(player.playbackRate - rate) < 0.01 {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Text(rateLabel(player.playbackRate))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 42, minHeight: 36)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == 1 ? "1×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    @ViewBuilder
    private var mutePlayerButton: some View {
        Button {
            player.toggleMute()
            showPlayerControls()
        } label: {
            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .playerTopControl()
        }
        .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
    }

    @ViewBuilder
    private var loopPlayerButton: some View {
        Button {
            player.toggleLoopCurrentVideo()
            showPlayerControls()
        } label: {
            Image(systemName: "repeat.1")
                .playerTopControl()
                .opacity(player.isLoopingCurrentVideo ? 1 : 0.58)
        }
        .accessibilityLabel("Loop video")
        .accessibilityValue(player.isLoopingCurrentVideo ? "On" : "Off")
    }

    private func watchURL(_ video: Video) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(video.id)")
    }

    /// `youtu.be/<id>?t=<seconds>` is the canonical share-with-timestamp URL YouTube understands.
    private func watchURLAtCurrentTime(_ video: Video) -> URL? {
        let seconds = Int(player.elapsed)
        return URL(string: "https://youtu.be/\(video.id)?t=\(seconds)")
            ?? URL(string: "https://youtu.be/\(video.id)")
    }

    // MARK: - Queue controls

    /// Autoplay belongs with playback behavior, so keep it available with the player's other
    /// configurable top controls instead of coupling it to the Up Next panel's expanded state.
    @ViewBuilder
    private var autoplayPlayerButton: some View {
        Button {
            autoplayNext.toggle()
            showPlayerControls()
        } label: {
            Image(systemName: autoplayNext ? "play.circle.fill" : "play.circle")
                .playerTopControl()
                .opacity(autoplayNext ? 1 : 0.58)
        }
        .accessibilityLabel("Autoplay next")
        .accessibilityValue(autoplayNext ? "On" : "Off")
    }

    // MARK: - Queue panel sizing

    /// Fixed height of one queue row's content area. 56pt accommodates the 80×45 thumbnail with
    /// a hair of breathing room. Combined with our `.listRowInsets(top: 4, bottom: 4)` each row
    /// occupies 64pt of vertical space in the List.
    private static let queueRowHeight: CGFloat = 56

    /// Per-row footprint including insets, used by `queueListHeight` below.
    private static let queueRowFootprint: CGFloat = queueRowHeight + 8 // 4pt top + 4pt bottom insets

    /// Total height we hand to the queue `List`. Sized for the actual number of items + a 32pt
    /// bottom margin so the last row's edit-handle / swipe affordance isn't truncated.
    private var queueListHeight: CGFloat {
        let loadMoreRows = canRevealMoreUpNext ? 1 : 0
        let count = max(1, displayedUpNextVideos.count + loadMoreRows)
        return CGFloat(count) * Self.queueRowFootprint + 32
    }

    private var playlistListHeight: CGFloat {
        let controls = (playlistWindowLowerBound > 0 ? 1 : 0)
            + (playlistWindowUpperBound < player.queue.items.count || player.canLoadMorePlaylistItems ? 1 : 0)
        return CGFloat(max(1, displayedPlaylistIndices.count + controls)) * Self.queueRowFootprint + 32
    }

    private var playlistWindowLowerBound: Int {
        max(0, player.queue.currentIndex - playlistItemsBefore)
    }

    private var playlistWindowUpperBound: Int {
        min(player.queue.items.count, player.queue.currentIndex + playlistItemsAfter + 1)
    }

    private var displayedPlaylistIndices: Range<Int> {
        playlistWindowLowerBound..<playlistWindowUpperBound
    }

    private var displayedQueueIndices: [Int] {
        player.queue.items.indices.filter { player.queue.items[$0].id != player.currentVideo?.id }
    }

    private var allUpNextVideos: [Video] {
        player.activePlaylist == nil
            ? displayedQueueIndices.map { player.queue.items[$0] }
            : player.playlistRecommendations
    }

    private var displayedUpNextVideos: [Video] {
        Array(allUpNextVideos.prefix(max(1, upNextVisibleLimit)))
    }

    private var canRevealMoreUpNext: Bool {
        upNextVisibleLimit < allUpNextVideos.count || player.canLoadMoreRecommendations
    }

    // MARK: - Queue panel

    @ViewBuilder
    private var playlistPanel: some View {
        if let playlist = player.activePlaylist {
            VStack(alignment: .leading, spacing: 8) {
                collapsiblePanelHeader(
                    title: "Playlist · \(playlist.title)",
                    isExpanded: $isPlaylistExpanded,
                    onOpen: { openPlaylist(playlist.id) }
                )
                if isPlaylistExpanded {
                    List {
                        if playlistWindowLowerBound > 0 {
                            Button {
                                playlistItemsBefore += 20
                            } label: {
                                Label("Load 20 previous", systemImage: "chevron.up")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.queueRowHeight)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                        ForEach(displayedPlaylistIndices, id: \.self) { index in
                            queueRow(player.queue.items[index], preservesPlaylistContext: true)
                                .listRowBackground(Color.clear)
                                .frame(height: Self.queueRowHeight)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                        if playlistWindowUpperBound < player.queue.items.count {
                            Button {
                                playlistItemsAfter += 20
                            } label: {
                                Label("Load 20 next", systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.queueRowHeight)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        } else if player.canLoadMorePlaylistItems {
                            loadMoreQueueButton(isLoading: player.isLoadingMorePlaylistVideos) {
                                await player.loadMorePlaylistItems()
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: playlistListHeight)
                }
            }
        }
    }

    @ViewBuilder
    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.smooth(duration: 0.28)) {
                        isQueueExpanded.toggle()
                    }
                } label: {
                    HStack {
                        SectionHeader(title: "Up next")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.smooth(duration: 0.28)) {
                        isQueueExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isQueueExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            // `List` is the cleanest source of drag-to-reorder + swipe-to-delete in SwiftUI. We're
            // already inside a ScrollView, so we cap the list with a generous fixed height so it
            // doesn't try to consume the outer scroll's gesture space.
            // Keep List mounted at its final size and animate a clipping window around it. Inserting
            // a List conditionally makes SwiftUI perform its internal row layout in one frame,
            // which produces the visible jump that used to interrupt the expansion.
            ZStack(alignment: .top) {
                List {
                    ForEach(displayedUpNextVideos) { video in
                        queueRow(video, preservesPlaylistContext: false)
                            .listRowBackground(Color.clear)
                            .frame(height: Self.queueRowHeight)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    if canRevealMoreUpNext {
                        Button {
                            Task { await revealMoreUpNext() }
                        } label: {
                            HStack {
                                Spacer()
                                if player.isLoadingMoreRecommendations {
                                    ProgressView()
                                } else {
                                    Label("Load more", systemImage: "chevron.down")
                                        .font(.subheadline.weight(.medium))
                                }
                                Spacer()
                            }
                            .frame(height: Self.queueRowHeight)
                        }
                        .buttonStyle(.plain)
                        .disabled(player.isLoadingMoreRecommendations)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: queueListHeight)
            }
            .frame(height: isQueueExpanded ? queueListHeight : 0, alignment: .top)
            .clipped()
            .opacity(isQueueExpanded ? 1 : 0)
            .allowsHitTesting(isQueueExpanded)
        }
        .onChange(of: player.currentVideo?.id) {
            isQueueExpanded = false
            upNextVisibleLimit = upNextInitialCount
        }
        .onChange(of: upNextInitialCount) { _, newValue in
            upNextVisibleLimit = newValue
        }
        .onAppear { upNextVisibleLimit = upNextInitialCount }
    }

    private func revealMoreUpNext() async {
        let increment = 5
        if upNextVisibleLimit < allUpNextVideos.count {
            upNextVisibleLimit = min(upNextVisibleLimit + increment, allUpNextVideos.count)
            return
        }
        await player.loadMoreRecommendations()
        upNextVisibleLimit = min(upNextVisibleLimit + increment, allUpNextVideos.count)
    }

    private func collapsiblePanelHeader(
        title: String,
        isExpanded: Binding<Bool>,
        onOpen: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                SectionHeader(title: title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open playlist")
            }
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private func openPlaylist(_ playlistID: String) {
        player.fullScreenPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if playlistID.hasPrefix("local:") {
                NotificationCenter.default.post(
                    name: .freetubeOpenLocalPlaylist,
                    object: String(playlistID.dropFirst("local:".count))
                )
            } else {
                NotificationCenter.default.post(name: .freetubeOpenPlaylist, object: playlistID)
            }
        }
    }

    private func loadMoreQueueButton(
        isLoading: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    Label("Load more", systemImage: "chevron.down")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
            }
            .frame(height: Self.queueRowHeight)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    @ViewBuilder
    private func queueRow(_ video: Video, preservesPlaylistContext: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                player.load(video, skipRecommendations: preservesPlaylistContext, audioOnly: player.isAudioOnlySession)
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail with duration badge in the bottom-right corner — same affordance
                    // YouTube uses on its own video tiles. Costs no extra row height.
                    ZStack(alignment: .bottomTrailing) {
                        KFImage(video.thumbnailURL)
                            .thumbnail(size: CGSize(width: 80, height: 45)) {
                                Color.gray.opacity(0.2)
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 45)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if !video.durationString.isEmpty {
                            Text(video.durationString)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    video.isLive ? Color.red : Color.black.opacity(0.78),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                                .padding(3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.subheadline)
                            .foregroundStyle(
                                preservesPlaylistContext && video.id == player.currentVideo?.id
                                    ? Color.accentColor
                                    : Color.primary
                            )
                            .lineLimit(2)
                        // Channel name + playback count joined by a middle dot. Either piece can be
                        // empty (older listings sometimes omit view count), filter before joining so
                        // there are no stray separators.
                        Text(queueRowMetadata(for: video))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if video.id == player.currentVideo?.id, !preservesPlaylistContext {
                        // Animated audio bars instead of the static speaker glyph. Animates only
                        // for the matched row; other rows render nothing because the parent `if`
                        // gates mounting.
                        NowPlayingIndicator(videoID: video.id)
                    }
                }
            }
            .buttonStyle(.plain)

            // Sibling of the load-button so taps land in the Menu instead of the row's
            // play handler. Same actions as the row would get in search/history/library.
            VideoMoreActionsMenu(
                video: video,
                offersPlayNext: !preservesPlaylistContext,
                onRemoveFromUpNext: preservesPlaylistContext ? nil : {
                    player.removeFromUpNext(videoID: video.id)
                }
            )
        }
        .background {
            if preservesPlaylistContext, video.id == player.currentVideo?.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            }
        }
    }

    /// "Channel • 1.2M views" for the queue row's second line. Drops the dot if either side is
    /// missing so we never render a dangling separator.
    private func queueRowMetadata(for video: Video) -> String {
        [video.channelName, video.viewCountString]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
