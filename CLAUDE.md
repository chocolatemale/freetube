# CLAUDE.md

This file gives Claude Code the context, constraints, and conventions it must follow when working in this repository. Read it fully before touching any code. Re-read it when starting a new session.

---

## 1. What this project is

**FreeTube iOS** — a native SwiftUI YouTube client that replicates the YouTube mobile app: home feed, search, playback, login, subscriptions, library, history, playlists, comments, likes, downloads. Plus a "Link" tab for downloading from any of ~2,000 sites supported by yt-dlp.

**Distribution:** TestFlight internal, sideload, or personal use. **Not for public App Store submission.** Do not suggest changes that assume App Store distribution.

**Platforms:** iOS 17.0+, Swift 5.9+, Xcode 15+.

**Bundle identifier:** `com.leshko.freetube`. This is also the reverse-DNS namespace for the `os.Logger` subsystem, the Keychain cookie key (`com.leshko.freetube.cookies`), the `UserDefaults` keys (subscriptions / downloads / metadata), and internal `Notification.Name`s. Keep all of them on this same domain. Changing the identifier invalidates provisioning profiles and resets Keychain / `UserDefaults` state for any prior install.

---

## 2. Non-negotiable constraints

These come first. Violating them breaks the project.

1. **No Google Cloud YouTube Data API.** Feeds, metadata, and account interaction go through `b5i/YouTubeKit`; native playback resolution goes through the vendored `alexeichhorn/YouTubeKit` snapshot exposed as `FreeTubeStreamKit`. Neither requires an API key. Never suggest `GoogleAPIClientForREST`, `YTPlayerView`, IFrame embeds, or `https://www.googleapis.com/youtube/v3/...`.
2. **No `dimitris-c/AudioStreaming`.** It is for raw audio streams (Icecast/Shoutcast). YouTube serves HLS/DASH. Playback uses `AVPlayer` only.
3. **No App Store assumptions.** Do not add capabilities, entitlements, or workarounds aimed at App Store review (e.g. avoiding `WKWebView` cookie reads, hiding download functionality). Sideload-honest behavior is expected.
4. **No telemetry, analytics, or remote logging by default.** Logs go to `os.Logger` only. Never add SDKs that beacon out.
5. **Cookies are sensitive.** Always store in Keychain via `KeychainHelper`. Never write them to disk, `UserDefaults`, plist, or logs. Never print cookie values.
6. **Signed stream URLs are sensitive and time-limited.** Never persist them. In-memory cache only (`StreamURLCache`), 30-minute TTL max.
7. **MVVM with service layer is mandatory.** Views do not import `YouTubeKit` or `YoutubeDL`. ViewModels do not perform networking directly — they call services in `Core/Networking/`.
8. **SwiftUI only for UI.** No UIKit `UIViewController` subclasses except where bridging is unavoidable (`AVPlayerViewController`, `WKWebView`, `AVPictureInPictureController`). Wrap those in `UIViewControllerRepresentable` / `UIViewRepresentable`.
9. **Swift Concurrency is the default.** Use `async`/`await` and `AsyncSequence`. Use Combine only inside `PlayerStateManager` for `AVPlayer` time observation. Do not introduce RxSwift.
10. **No force unwraps in production code.** Use `guard let`, `if let`, or proper `throw`. Force unwraps allowed only in test fixtures.
11. **`@Observable` is the default for view models, not `ObservableObject`.** Injected through SwiftUI `@Environment(...)`.

---

## 3. Tech stack (locked)

| Layer | Choice |
|---|---|
| UI | SwiftUI (`@Observable`, iOS 17 APIs) |
| Async | Swift Concurrency, `AsyncSequence` |
| Networking (YouTube) | `b5i/YouTubeKit` |
| Native stream resolution | `alexeichhorn/YouTubeKit` 0.4.9, vendored as `FreeTubeStreamKit` |
| Stream extraction / download | `kewlbear/YoutubeDL-iOS` (yt-dlp via `PythonKit`) |
| In-process ffmpeg | `FFmpegSupport` (Swift wrapper around ffmpeg C library) |
| Playback | `AVFoundation` / `AVKit` (`AVQueuePlayer`, `AVPlayerViewController`, `AVPictureInPictureController`) |
| Mini / expanded player | `LNPopupUI` 4.0.1 / `LNPopupController` 4.5.9 |
| Now-playing indicator | `SwimplyPlayIndicator` |
| Login web view | `WebKit` (`WKWebView`, `WKHTTPCookieStore` against ephemeral `.nonPersistent()` data store) |
| Images | `Kingfisher` |
| Secure storage | `Security` (raw Keychain via `KeychainHelper`) |
| Persistence | `SwiftData` (`@Model`); `UserDefaults` for simple flags via `UserPreferences` |
| Background work | `audio` background mode only. Downloads run in-process (yt-dlp / `NativeHLSDownloadService`); there is no background `URLSession` — the unused scaffolding was removed in the 2026-09 security audit |
| Logging | `os.Logger` with subsystem `com.leshko.freetube` |
| JavaScript runtime | `JavaScriptCore` (`JSContext`) — solves YouTube's N/SIG cipher challenges in-process by faking the `deno` runtime to yt-dlp; see §15.11 |

The `b5i/YouTubeKit` project reference tracks `main`, but Xcode and CI honor the revision in
`Package.resolved`. When updating playback extraction, update that resolved revision as well;
otherwise builds silently continue using the older pinned implementation.

Adding any other dependency requires an explicit ask in the PR description with justification.

---

## 4. Project structure

```
FreeTube/
├── App/
│   ├── AppEnvironment.swift
│   └── RootView.swift
├── FreeTubeApp.swift
├── Core/
│   ├── Networking/        # YouTubeKit wrappers, one Service per response family
│   ├── Auth/              # CookieStore, KeychainHelper, LoginCoordinator,
│   │                      # SessionManager, SubscriptionRegistry, AuthState
│   ├── Player/            # PlayerStateManager, PlaybackResolver, QueueManager,
│   │                      # AudioSessionConfigurator, NowPlayingCenter,
│   │                      # RemoteCommandCenter, StreamURLCache, HLSResourceLoaderDelegate
│   ├── Download/          # DownloadManager (yt-dlp orchestration),
│   │                      # DownloadTask, YtDlpUpdater (verified weekly refresh)
│   ├── JavaScript/        # JSEvaluator (JSContext wrapper), PythonJSBridge
│   │                      # (yt-dlp ↔ JSCore glue), FreeTubeYtDlp (forked
│   │                      # entry point that splices the bridge), EJSResources
│   │                      # (loader for bundled yt-dlp-ejs JS)
│   ├── Persistence/       # @Model types, PersistenceController, PersistenceWriter
│   └── Models/            # Domain types: Video, Channel, Playlist, Comment,
│                          # VideoFormat, VideoQuality, ErrorState,
│                          # PlaybackSource, UserPreferences, YouTubeServiceError
├── Features/
│   ├── Home/              # HomeScreen + HomeViewModel
│   ├── Search/            # SearchScreen, SearchSuggestionList, SearchViewModel
│   ├── Subscriptions/     # SubscriptionsScreen + ViewModel
│   ├── Library/           # LibraryScreen, HistoryScreen, SubscribedChannelsScreen, ViewModels
│   ├── Channel/           # ChannelScreen, ChannelTabScreen, ViewModel
│   ├── Playlist/          # PlaylistScreen + ViewModel
│   ├── VideoDetail/       # VideoDetailScreen, CommentsSection, SaveToPlaylistSheet, ViewModels
│   ├── Account/           # AccountScreen + ViewModel
│   ├── Login/             # LoginScreen, LoginWebView
│   ├── Downloads/         # DownloadsScreen + ViewModel
│   └── Settings/          # SettingsScreen + ViewModel
├── UI/
│   ├── Player/            # FullScreenPlayer, PlayerSurface, DownloadProgressOverlay
│   ├── Components/        # VideoCard, VideoRow, ChannelRow, CommentRow,
│   │                      # PlaylistRow, AddToPlaylistSheet, ActivityShareSheet,
│   │                      # NowPlayingIndicator, SectionHeader, LoadingView
│   └── Modifiers/         # ErrorToastModifier
├── Resources/
│   ├── Localizable.xcstrings    # en / es / ru / fr / de, 236 keys
│   ├── core.min.js              # yt-dlp-ejs N/SIG solver (~7 KB, see §15.11)
│   └── lib.min.js               # meriyah + astring bundle (~152 KB, see §15.11)
└── Assets.xcassets
```

When asked to "add a feature", create or extend a folder under `Features/`. Keep shared UI atoms in `UI/Components/`.

---

## 5. File and naming conventions

- One type per file. File name matches the type name.
- Service classes end in `Service` (`SearchService`, `HistoryService`).
- View models end in `ViewModel`, declared `@Observable` (iOS 17+).
- SwiftUI views are nouns (`VideoCard`, `HomeScreen`). Use `Screen` suffix for top-level screens.
- Async functions return concrete types or throw — no `Result` returns from public service APIs.
- Use `// MARK: -` to separate logical sections in files over 100 lines.
- Annotate iOS-17-only types with `@available(iOS 17.0, *)` even though the deployment target is 17.0 — it documents the dependency and keeps the build clean if the target ever drops.

---

## 6. Mandatory mapping: YouTubeKit response → service method → ViewModel

Every YouTubeKit response type gets exactly one service method. Do not call `YouTubeKit` from anywhere except `Core/Networking/`. Source of truth:

| Response | Service method |
|---|---|
| `HomeScreenResponse` (+Continuation) | `HomeService.fetchHome()` / `fetchMore()` |
| `TrendingVideosResponse` | `HomeService.fetchTrending()` |
| `SearchResponse` (+Continuation, +Restricted) | `SearchService.search(query:restricted:)` / `fetchMore()` |
| `AutoCompletionResponse` | `SearchService.autocomplete(query:)` |
| `ChannelInfosResponse` (+Videos/Shorts/Directs/Playlists +Continuations) | `ChannelService.fetchChannel(id:)` / `fetchVideos()` / `fetchShorts()` / `fetchDirects()` / `fetchPlaylists()` |
| `PlaylistInfosResponse` (+Continuation) | `PlaylistService.fetchPlaylist(id:)` / `fetchMore()` |
| `VideoInfosResponse` | `VideoService.fetchInfo(id:)` (iOS client) — **also `VideoService.fetchInfoViaTVHTML5(id:)`** (TVHTML5_SIMPLY_EMBEDDED_PLAYER context for PoT-resistant URLs) |
| `VideoInfosWithDownloadFormatsResponse` | `VideoService.fetchInfoWithFormats(id:)` |
| `MoreVideoInfosResponse` (+RecommendedVideosContinuation) | `VideoService.fetchMoreInfo(id:)` / `fetchRecommendedVideos(continuation:)` |
| `AccountInfosResponse` | `AccountService.fetchAccountInfo()` |
| `AccountLibraryResponse` | `AccountService.fetchLibrary()` |
| `AccountPlaylistsResponse` | `AccountService.fetchPlaylists()` |
| `AccountSubscriptionsFeedResponse` | `SubscriptionService.fetchFeed()` |
| `AccountSubscriptionsResponse` | `SubscriptionService.fetchSubscriptions()` |
| `HistoryResponse` / `RemoveVideoFromHistroryResponse` | `HistoryService.fetch()` / `remove(videoID:)` |
| `SubscribeChannelResponse` / `UnsubscribeChannelResponse` | `SubscriptionService.subscribe(channelID:)` / `unsubscribe(channelID:)` |
| `AllPossibleHostPlaylistsResponse` | `PlaylistService.fetchHostablePlaylists(videoID:)` |
| `AddVideoToPlaylistResponse` / `RemoveVideoByIdFromPlaylistResponse` / `RemoveVideoFromPlaylistResponse` | `PlaylistService.add/remove*` |
| `CreatePlaylistResponse` / `DeletePlaylistResponse` / `MoveVideoInPlaylistResponse` | `PlaylistService.create/delete/move*` |
| `LikeVideoResponse` / `DislikeVideoResponse` / `RemoveLikeFromVideoResponse` | `VideoActionsService.like/dislike/removeRating*` |
| `CreateCommentResponse` / `EditCommentResponse` / `DeleteCommentResponse` | `CommentService.create/edit/delete*` |
| `ReplyCommentResponse` / `EditReplyCommandResponse` | `CommentService.reply/editReply*` |
| `LikeCommentResponse` / `DislikeCommentResponse` / `RemoveLikeCommentResponse` / `RemoveDislikeCommentResponse` | `CommentService.like/dislike/removeRating*` |
| `CommentTranslationResponse` | `CommentService.translate(commentID:)` |

If a feature seems to need data without a clear mapping above, stop and ask before improvising.

---

## 7. Playback pipeline (critical)

Playback is stream-first. `PlayerStateManager` calls `PlaybackResolver`, installs the returned URL
in an `AVPlayerItem`, and never imports either extraction library itself. Resolution order is:

1. **Existing local file.** `DownloadManager.localFile(for:)` wins immediately, preserving offline playback.
2. **Native local extraction, HLS-first.** `NativeStreamService` uses `FreeTubeStreamKit` with `methods: [.local]`. It reads the InnerTube player response's `hlsManifestUrl` **before** touching `youtube.streams`, for live and on-demand alike. That path never runs the JavaScriptCore signature/n-parameter solver, which re-parses the whole ~2.5 MB player.js once per InnerTube client and was costing ~4s per play for a result the resolver then discarded in favour of this same HLS URL. Progressive selection (natively playable audio+video within `preferredQuality.heightCap`) runs only when no HLS manifest exists. Audio-only still starts from the HLS master, then takes its default audio media playlist — do not play progressive itag 140 DASH `m4a` first. Those files often have an empty `stts` atom, so AVPlayer reports about twice the real duration and plays silence in the second half. When that leftover stream still wins, `AudioPlaybackDuration` clamps the timeline to `Video.duration` and synthesizes natural end so auto-next does not wait out the pad. The dependency's hosted remote extractor is never enabled. Candidates are AVPlayer-validated.
  The same cached player response also supplies `playerStoryboardSpecRenderer`; the native result carries that dependency-neutral storyboard with the stream candidate, so previews require no second player request.
3. **b5i direct streams, validated by AVPlayer.** `PlaybackResolver` produces iOS and then TVHTML5 HLS/progressive candidates through `VideoService`. These sit *behind* the native resolver: for ordinary VOD, `VideoInfosResponse` reports no HLS URL and its formats carry metadata without usable URLs (upstream documents that real URLs require `VideoInfosWithDownloadFormatsResponse.deciphersURLs(player:)`), so running them first spent ~1.5s per play on candidates that could not be produced. `PlayerStateManager` only accepts a candidate after its `AVPlayerItem` reaches `.readyToPlay`; failure or a four-second readiness timeout advances to the next strategy.
4. **Legacy download fallback.** Only after every direct resolver fails, `DownloadManager.ensureDownloaded` runs the existing yt-dlp → YouTubeKit download pipeline. Explicit Download actions remain unchanged and continue to call `DownloadManager` directly.

Because HLS is now the usual source, `PlayerStateManager.applyQualityCap` sets
`AVPlayerItem.preferredMaximumResolution` from `preferredQuality.heightCap` so the user's quality
setting still bounds ABR variant selection. `.auto` stays uncapped.

**Playback starts optimistically.** `resolveAndPlay` installs the candidate, sets
`loadState = .buffering`, and calls `play()` right away instead of waiting for `.readyToPlay`. This
is purely about perceived latency: warm resolution is ~0.4s but AVPlayer readiness is ~2s, i.e. ~80%
of the tap-to-video wait, and AVPlayer exposes no "first frame rendered" signal to key off.

**`automaticallyWaitsToMinimizeStalling` must stay `true`, and setting it to `false` breaks
playback outright.** It reads like the lever that makes an optimistic start take effect sooner; it is
the opposite. `AVPlayer.rate` ignores a nonzero rate set while the current item isn't ready, so the
only reason the early `play()` survives to readiness is that `true` parks the player in
`.waitingToPlayAtSpecifiedRate`, from which it starts on its own. With `false` there is no holding
state: the call is discarded, `timeControlStatus` never changes, and — because `play()` sets
`isPlaying = true` as a UI prediction — nothing downstream notices. The video sits on its thumbnail
until the user pauses and plays again. Correspondingly, the `.readyToPlay` retry is gated on
`player.timeControlStatus == .paused`, never on `isPlaying`, which is a prediction rather than an
observation and reads `true` whether or not AVPlayer honoured the request.

**Validation is unchanged.** A candidate is still only *accepted* on `.readyToPlay`; on `.failed` or
a readiness timeout the strategy goes into `excludedStrategies`, the transport is paused (the
optimistic `play()` left it playing or waiting-to-play on a stream we're abandoning, and `isPlaying`
/ NowPlaying must not keep advertising it), the queue is emptied, and the loop asks for the next
candidate. Readiness
is observed through KVO on `AVPlayerItem.status` — the single observation installed by
`observe(item:)`, never a second competing one — feeding a continuation, which replaced a 100ms
polling loop. That continuation is resumed exactly once, by whichever of KVO, the timeout task, or
task cancellation arrives first; every path funnels through `finishReadiness(_:token:)` on the main
actor, and the token exists so a late waker can't settle a newer candidate's wait.

Automatic next-item download prefetch is disabled. Recommendation queue filling remains independent
and still runs after playback begins. Signed URLs are used immediately or stored only in
`StreamURLCache` with its 30-minute maximum TTL. Rapid video changes cancel the prior resolution;
the player also checks the selected video ID before installing a result.

### Shape

```swift
enum PlaybackSource {
    case direct(URL)
    case localFile(URL)
}
```

`AVQueuePlayer` accepts both cases identically; the player consumes `PlaybackSource.url`. A returned
URL is a candidate, not proof of playback: resolver strategy names are logged (never signed URLs),
and a rejected strategy is excluded before requesting the next candidate.

---

## 8. Player UI rules

- **One `PlayerStateManager`** is the single source of truth for current playback. Injected via SwiftUI `@Environment(PlayerStateManager.self)`.
- **Mini player and full-screen player are both driven by `LNPopupUI`** — the popup bar above the tab bar expands into a full-screen popup. Same `AVQueuePlayer` instance for both views. Tapping a channel in the expanded player collapses it, selects Search, and pushes `ChannelScreen` onto Search's native `NavigationStack`; Back returns to Search while the mini-player keeps playing.
- **Direct video selections open the expanded player immediately.** `PlayerStateManager.load` defaults `expandPlayer` to `true`; automatic next/previous transitions pass `false` so they preserve whatever popup state the user chose. The native mini-player bar can be dismissed with a downward swipe, which must call `PlayerStateManager.dismiss()` so playback, resolution, Now Playing, and popup state are torn down together. Upward drags remain available for expansion.
- **Mini-player title/subtitle use LNPopupUI's native string labels with marquee disabled.** On iOS 26, both LNPopupController's marquee and a SwiftUI replacement proved capable of clipping, accelerating, or disappearing as popup metadata changed. Static native labels are the stable configuration: long text truncates but stays vertically centred. Keep `.popupBarMarqueeScrollEnabled(false)`. The popup packages remain pinned to LNPopupUI 4.0.1 / LNPopupController 4.5.9. Its small explicit X is a leading popup button before the thumbnail and calls `PlayerStateManager.dismiss()` so playback and popup state are torn down together.
- **`AVPlayerViewController`** wrapped in `UIViewControllerRepresentable` (`PlayerSurface.swift`) remains the video-rendering and automatic-PiP engine, with `showsPlaybackControls = false` and video-frame analysis disabled. `CustomPlayerControls` owns the visible YouTube-style play/pause/replay, previous/next buttons, auto-hide chrome, and `SponsorBlockTimeline`; `FullScreenPlayer` renders the configurable top-right controls. `PlayerStateManager.hasEnded` is the authoritative natural-end state. The underlying `AVQueuePlayer` must use `actionAtItemEnd = .pause`; its default `.advance` removes the sole finished item, producing a black surface and leaving replay with nothing to seek. The app's end observer owns automatic queue advancement instead. An exhausted item therefore remains on its final frame, replay seeks that existing item to zero without resolving again, and seeking backward resumes playback. Preferred quality remains a Settings-level ceiling because AVPlayer's HLS selection does not guarantee the displayed ceiling as the delivered rendition; do not present it as a strict in-player selector. HLS ceilings apply through `preferredMaximumResolution`, while fixed progressive/local assets retain their encoded quality and use the preference on the next resolution. Controls use unbacked white glyphs with shadows rather than dark button circles. Fullscreen requests landscape-right and toggles back to portrait. Speed, loop-current, mute, and fullscreen can each be hidden and reordered in the native Player controls settings screen; the collapse button remains fixed at leading. Loop is not duplicated in Up Next. Native icon-only Share and Download controls sit trailing on the uploader row. Share consolidates the system share sheet, browser, clipboard, timestamp, and downloaded-file actions. Download calls the existing `DownloadManager.ensureDownloaded` yt-dlp path and reflects active/completed state. There is no separate transport bar below the video and no bottom Close pill. The controls remain mounted and fade by opacity so their layout does not churn during auto-hide. The initial hide timer is scheduled when the first item reaches `.readyToPlay`, since the view normally appears before playback begins. During horizontal gesture seeking, the timeline alone becomes visible and follows the preview target even when the rest of the chrome is hidden. The video remains full-width in compact-height landscape; only the timeline is lifted by the portion of the 16:9 surface extending below the viewport. The timeline seeks only on drag end, places time labels above the track, emits one light haptic when a scrub crosses a chapter boundary, and renders enabled SponsorBlock segments at exactly the track's thickness. `PlayerStateManager.seek` pins its optimistic target until AVPlayer confirms the seek (plus a short stale-tick drain), preventing the scrubber from flashing back to the old periodic-observer position. Automatic PiP-on-background is enabled; reopening the expanded player cycles `allowsPictureInPicturePlayback` off long enough to terminate its internally owned PiP presentation, then restores eligibility for the next background transition. There is intentionally no AirPlay or manual PiP button.
- **Player gestures recognize on `AVPlayerViewController.view`.** `contentOverlayView` is used only to draw feedback; it does not receive player touches on iOS 26. `PlayerGestureCoordinator` attaches simultaneous, non-cancelling recognizers to the controller root for single-tap control toggling, a two-finger tap for play/pause, double-tap left/right seek −/+10 seconds, a direct horizontal-drag seek, and a 0.35-second hold for temporary 2× playback, restoring the prior rate on release. Two-finger playback toggling routes through `PlayerStateManager`, not directly through `AVPlayer`, so observable and Now Playing state remain synchronized. Play-state observation must not reveal the controls; each visible control action already does so explicitly, while gesture, remote, and automatic changes preserve chrome visibility. Horizontal seeking direction-locks only when horizontal velocity dominates vertical velocity, previews the signed offset from the drag's starting playback position in a compact top capsule, feeds that temporary target into the custom timeline, and commits on release. A slow full-width drag spans 60 seconds for videos below 30 minutes, 90 seconds below one hour, and 120 seconds for longer videos; horizontal velocity smoothly boosts the range up to 3× while vertical drags remain available to collapse the player. The coordinator owns a strict 0.22-second tap-pairing window instead of UIKit's more generous fixed double-tap timeout. After the initial pair, a 0.22-second seek session counts each additional tap as another −/+10 seconds and displays the cumulative offset (four taps total = 30 seconds); each tap resets the timeout. This single owner prevents successful seek taps from leaking into control visibility toggles.
- **Gesture feedback is compact and edge-biased.** The temporary 2× label uses a 52×26 capsule at
  10% of the video surface height. Double-tap feedback has no backing capsule: it uses bold white
  text with a subtle black shadow plus `≪`/`≫` direction glyphs at 18%/82% of the width. Horizontal-drag
  feedback is a 124×26 capsule at the top and shows only the signed offset.
- **SponsorBlock is opt-in and playback-independent.** `SponsorBlockService` performs a read-only
  k-anonymous hash-prefix lookup for only the selected video; it never submits skip/view telemetry
  and caches segment data in memory only. `PlayerStateManager` installs AVPlayer boundary-time
  observers without blocking stream resolution. Duration categories independently support Disabled,
  Show only (timeline marker), or Automatically skip. `poi_highlight` is a point marker and instead
  supports Disabled, Show only, or Ask; Ask presents a five-second prompt to jump to that timestamp
  as soon as the lookup returns. Manual seeks
  immediately evaluate their destination, and rewinding before a handled segment rearms it. Undo
  returns to the settled manual-seek position when the user landed inside a segment, while normal
  boundary skips return to the segment start; Undo is deliberately exempt from rearming so it can
  replay the segment without instantly skipping again. Automatic
  skips show the existing five-second Undo banner using the category color.
  Prompt/Undo banners sit above the custom timeline using the same orientation-aware bottom inset,
  so they never cover its time labels.
  AVKit has no public API for adding ranges to its native scrubber, so do not inspect or mutate its
  private seek-bar hierarchy; markers require a separate public/custom UI in a future change.
- **Expanded player details are resilient and optionally prefetched.** Tapping the video title toggles the description
  with a short animation. It stays expanded while `VideoService.fetchMoreInfo` loads the full
  description, retains a non-empty feed snippet when the fetched description is empty, shows
  “Description unavailable” on a genuine miss/failure, and offers an explicit retry.
  The default-on “Prefetch details and comments” preference starts only after AVPlayer accepts its
  playback candidate. `VideoContentPrefetchStore` deduplicates the `MoreVideoInfosResponse` already
  used for recommendations, caches at most twelve videos in memory, and fetches only the initial
  comments response; continuations and replies stay explicit. Disabling it restores fully lazy loads.
  The pinned b5i response exposes chapter title, start time, timestamp text, and thumbnails via
  `MoreVideoInfosResponse.chapters`; `VideoService` maps those into app-owned `VideoChapter` values.
  The timeline punches transparent separators at chapter boundaries and shows the active chapter beside
  elapsed time. That label opens a thumbnail chapter browser over the lower feed in portrait and
  in a trailing split column in landscape, leaving the video interactive; rows seek directly. A
  only a fresh downward gesture that begins with the list already at the top may dismiss it—a
  gesture that merely scrolls back to the top must end first. Preserve roughly 34 points of native
  ScrollView rubber-banding before transferring into a mildly resisted sheet drag, then settle
  using panel-relative distance and projected velocity without haptics. The
  complete sheet background must move with that drag so it reveals the live feed underneath;
  use solid black for OLED mode and material otherwise. Portrait shows a
  native-style drag indicator; landscape has no swipe dismissal and retains only its close button.
  Suspend LNPopupUI's global content drag only while that browser is presented so the gestures do
  not race; normal interactive feed-to-mini-player dragging must return as soon as it closes. In
  landscape, preserve the established video/sidebar geometry and constrain only the lower
  metadata/feed column to the width left of the chapter sidebar—never allow titles underneath it.
  Remove the landscape sidebar atomically (`.identity` transition): combining a trailing material
  transition with simultaneous player-column expansion leaves a one-frame strip on the right.
  Native extraction wraps `playerStoryboardSpecRenderer` in an app-owned `VideoStoryboard` and
  carries it with the successful playback candidate. The storyboard and signed stream URL share
  the existing 30-minute in-memory cache; no redundant b5i player request is made. b5i fallback
  candidates can still supply `VideoInfosResponse.storyboard`. Only a direct drag on the timeline shows the
  cropped sprite tile, positioned close above and following the scrubber while remaining clamped inside
  the video edges. The compact tile has no duplicate timestamp or dark card—only a thin white border.
  Horizontal swipe seeking still previews its target on the timeline without a tile.
  The stats row is always visible directly beneath the title, outside the expandable description.
  It shows views plus an explicitly labelled upload date/relative upload value, never the video
  duration (duration already belongs in the player timeline). Prefer the exact display strings from
  the prefetched response and fall back to the `Video` summary fields while that request is pending.
- **Up Next and Comments are always present as independent collapsed sections.** There is no
  queue/comments mode switch. Mounting `CommentsSection` must not fetch comments: it defaults
  collapsed and performs its first request only when the user expands it, preserving the player's
  no-comment-load performance characteristics. Both section headers are tappable across their
  available width. The current video is hidden from the visible Up Next rows; compact autoplay and
  repeat icons appear beside the heading only while Up Next is expanded. Queue deletion
  uses swipe actions rather than permanent edit-mode minus controls. Existing comment replies use
  YouTubeKit's reply continuation token and load only when their inline like-row control is expanded.
  YouTubeKit has no literal comments-disabled Boolean. Treat a `MoreVideoInfosResponse` with neither
  a continuation token nor a comments header/count as disabled and show that state after expansion;
  a present zero-count header is an available empty section, not disabled. Preserve its formatted
  comment count in `VideoInfo` and show it in the collapsed section heading. Keep expanded metadata
  app-owned: structured description runs map to `VideoDescriptionPart`; timestamp-shaped runs seek
  locally even when YouTube labels them as video links, while ordinary links use the system handler
  after unwrapping YouTube tracking redirects. AVPlayer's display-correct `presentationSize` expands
  tall portrait media. On iOS 18+, native `onScrollGeometryChange` progressively compresses it
  toward 16:9 over a scroll range equal to the height difference; retain the geometry probe only as
  the iOS 17 fallback. The lower panel reserves that range even when its content is short and
  counteracts its own content offset with measured top padding until the collapse completes, so
  player compression happens first and ordinary feed scrolling begins only at the compact player
  border. Do not use a visual offset here: it makes the bottom of long comment lists unreachable.
  Cached MoreVideoInfos metadata may replace
  direct-URL placeholder titles/uploader details without restarting playback.
- **Search is search-only.** Its root contains local recent searches or the clean empty state; it
  must not request or render a home/trending/discovery feed. Native search presents suggestions,
  and a successful keyboard/suggestion/history submission swaps the root content to results in
  place—the same native search bar and query remain mounted, with no results-page push animation.
  The native clear button in the search field—or a swipe from the leading screen edge—clears that
  result/query state and reveals recent searches; do not add a separate Back button. Keep the
  search presentation mounted after submission so the submitted query and native clear button stay
  visible. Channels and playlists still push normally from their result rows. Results include
  videos, channels, and playlists. iPhone and iPad retain native
  `.searchable` (including the system Liquid Glass treatment); Mac uses an inline field because
  native search collapses awkwardly there. Search stays an ordinary peer tab—never assign
  `TabRole.search`, which detaches it visually on iOS 26. Re-selecting the ordinary tab increments a
  selection-binding activation token that drives `.searchable(isPresented:)`; it returns from any
  pushed destination and focuses the field without clearing the current query or results. The live
  field value and last submitted query are tracked separately, so editing a displayed query reveals
  its live suggestions rather than leaving stale results in front. Keyboard disappearance never
  mutates search-presentation state; that coupling made the navigation bar jump during scroll.
  No UIKit tab gesture observer is
  installed. Selecting a suggestion or history entry passes that row's query explicitly
  to the search submission before resigning keyboard focus; never rely on a later read of field state.
  Selecting a video also resigns focus without dismissing the search UI. Never attach a parent tap
  or drag recognizer around the search `List`: even a simultaneous gesture mask can consume native
  row and Clear-all buttons on iOS 26. The true empty state handles its own background tap, and every
  Search scroll container uses immediate keyboard dismissal as soon as scrolling begins.
- **Direct YouTube URLs submitted through Search start playback immediately.** Accept `youtu.be`
  links plus YouTube `/watch?v=`, `/shorts/`, `/embed/`, and `/live/` forms, with or without a scheme.
  Validate the extracted 11-character ID before creating a lightweight playback seed. Metadata is
  fetched through `VideoService` only after `PlayerStateManager.load` starts resolution, then applied
  only if that ID is still current; metadata enrichment must never restart or delay stream resolution.
- **`AVQueuePlayer`**, not `AVPlayer`. Required for `advanceToNextItem()` and queue introspection. Important: `replaceCurrentItem(with:)` is a no-op on `AVQueuePlayer` when its internal queue is empty (our usual state). Use `removeAllItems()` + `insert(_:after:)` (see the `loadItem` helper).
- **Background audio:** `AudioSessionConfigurator` runs at app launch with `(.playback, .moviePlayback)`. The optional “Allow audio from other apps” preference adds `.mixWithOthers` and reapplies the session immediately; it defaults off so FreeTube retains normal primary-media behavior. While another source is active, FreeTube remains secondary and does not fight for Now Playing ownership. Starting or resuming FreeTube when `isOtherAudioPlaying` is false reactivates the unchanged mixable session and republishes its metadata; stopping the other source alone does not trigger an automatic takeover.
- **Now Playing:** `NowPlayingCenter` keeps `MPNowPlayingInfoCenter.default().nowPlayingInfo` in sync — title, channel as artist, thumbnail (downloaded via Kingfisher) as artwork, elapsed/duration. Metadata and `MPMediaItemArtwork` are cached per current image; the 0.5-second playback tick updates only elapsed time and rate.
- **Remote commands:** `RemoteCommandCenter` wires `MPRemoteCommandCenter` for play/pause/next/previous/skip ±15s/seek.
- **The player area never shows a spinner on black while starting.** `PlayerArtworkBackdrop` paints `PlayerStateManager.currentArtwork` — the Kingfisher-cached thumbnail the user just tapped — over the video surface for every state except `.idle` / `.readyToPlay`, and `DownloadProgressOverlay` contributes only a small unlabelled spinner during `.resolving` / `.buffering`. Two constraints on that layer: it must sit *above* `PlayerSurface` in the ZStack (`AVPlayerViewController` paints its own opaque black background, so anything below it is invisible), and it must be `.allowsHitTesting(false)` or it swallows taps meant for the system playback controls. The dimmed scrim + text label + determinate bar treatment is reserved for `.downloading` and `.failed`, which are minutes-long or terminal and genuinely need words.
- **`LoadState.buffering` means "URL installed, `play()` already issued, AVPlayer not ready yet".** In that state the mini-player shows the real thumbnail and the channel name, not a placeholder glyph and "Preparing…" — the point of the state existing is that there is nothing left to prepare. Only `.downloading` (a real yt-dlp file transfer the user can't preview) still swaps in the download glyph.
- **Queue and navigation history are separate:** ordinary video loads replace the visible queue with the current video, then append at most 5 fresh recommendations. A private, bounded (50 item) browser-style playback history powers Previous/Next: Previous walks backward without adding rows to Up Next, and Next first walks forward to the video the user came from before resuming queue recommendations. Curated Play all / Shuffle all queues retain their explicit ordering and skip recommendation replacement. The Up next rows are collapsed by default so they do not participate in normal player redraws. On end-of-queue with repeat off, `playNext()` may re-fire recommendations using the current item as the seed.
- **Comments paginate only on explicit request.** `CommentsSection` uses a `LazyVStack` and a Load more button. Do not restore an eager `VStack` plus an `onAppear` pagination sentinel inside the player's outer `ScrollView`: SwiftUI lays out every row immediately there, which chains continuation requests and causes playback UI lag.
- **Long comments stay compact by default.** `CommentRow` limits long bodies to three lines and exposes an inline Read more / Show less control. Its inexpensive character/newline heuristic may produce occasional false-positive controls by design. The explicit comment continuation remains a compact neutral Load more button; it must never become an eager scroll sentinel.
- **Playback progress is local and conservative.** `PlayerStateManager` saves a YouTube video's position through `PersistenceWriter` at most every ten seconds and on pause, dismiss, or video replacement. Resume lookup runs concurrently with stream resolution and seeks only after the winning item is ready. Positions below ten seconds, within thirty seconds of the end, or beyond 95% are not resumed. Arbitrary Link-tab files are excluded.
- **Popup body backdrop is translucent unless OLED mode is enabled.** The expanded `FullScreenPlayer` normally paints a `.thinMaterial` rectangle behind the entire popup body. The explicit OLED preference replaces only that outer lower-player backdrop with true black; opaque black outside that preference is a regression. Common offenders + neutralizers:
  - **`NavigationStack` inside the popup body:** the nav bar paints an opaque system background even with the title hidden. `.toolbarBackground(.hidden, for: .navigationBar)` is NOT sufficient — use `.toolbar(.hidden, for: .navigationBar)` to remove the bar entirely. Supply your own back/close button.
  - **`List` / `ScrollView` default content background:** apply `.scrollContentBackground(.hidden)` on every list/scroll view in the popup body.
  - **`UIHostingController`-backed views (`NavigationStack` destinations):** add a defense-in-depth `.background { Rectangle().fill(.thinMaterial).ignoresSafeArea() }` on each destination root.
  - **Where you put `.background` matters.** Modifiers on `NavigationStack` itself (outside the trailing closure) paint *behind* its UIKit hosting container — its own opaque system background covers them. Backdrop must be applied *inside* the root content and again inside every `.navigationDestination { ... }` view.
  - **Don't replace the thinMaterial with `Color.black`** — that's not the intended look; the popup is designed as one continuous translucent surface over the tab content underneath.

---

## 9. Authentication flow

1. `LoginScreen` presents a `WKWebView` against an **ephemeral `.nonPersistent()` `WKWebsiteDataStore`**. The ephemeral store is critical — a persistent store reuses any prior session and we'd capture stale cookies.
2. `LoginCoordinator` watches navigation; when the URL transitions to `youtube.com` after sign-in, it calls `WKWebsiteDataStore.default().httpCookieStore.getAllCookies` and filters for `.youtube.com` / `.google.com` domains.
3. **Cookie de-duplication:** when both `.youtube.com` and `.google.com` versions of the same cookie are present, **prefer `.youtube.com`** (`CookieStore.dedupe`). Length-based tie-breaking failed in practice — both scopes were 12 chars. YouTube-scoped cookies are the ones YouTube actually accepts.
4. Required cookies (all must be present): `SAPISID`, `__Secure-3PAPISID`, `LOGIN_INFO`, `SID`, `HSID`, `SSID`, `APISID`.
5. Cookies are serialized as a single Cookie-header string and stored in Keychain under `com.leshko.freetube.cookies` via `KeychainHelper`.
6. On every app launch, `SessionManager.bootstrap()` reads from Keychain and assigns to `YouTubeModel.shared.cookies` plus `YouTubeKitClient.shared.applyCookies(...)`.
7. **`SubscriptionRegistry`** persists the user's subscribed channel IDs in `UserDefaults` (`com.leshko.freetube.subscriptions`). Subscribe/unsubscribe optimistically flips this **and** calls the YouTube endpoint. Needed because YouTubeKit's `subscribeStatus` parser doesn't follow `pageHeaderRenderer` entity-key indirection — channel screens were always showing "Subscribe" even on subscribed channels until this cache was added.
8. **`AuthState`** (an `@Observable` singleton) drives root navigation: `.loggedIn` / `.loggedOut` / `.unknown`. On `cookieExpired` / 401-equivalent failures, `SessionManager.handleExpiredSession()` wipes Keychain + sets `AuthState.loggedOut` and the root re-routes to Login.

---

## 10. Downloads

### User-initiated (Download button)

- `DownloadManager.ensureDownloaded(video:quality:priority: .background)` from the explicit Download button in the player menu.
- Files go to the app container's canonical `Documents/<videoID>.mp4` and are discovered through
  `DownloadsStore` filesystem metadata. Resolve that directory through `AppDirectories.documents`:
  embedded Python can corrupt Foundation's lazy `.documentDirectory` search-path result into a
  nested stale-container path.
- Visible in the Downloads screen, playable offline.

### Playback-side download (compatibility fallback)

- `PlaybackResolver` calls `ensureDownloaded` at `.userInitiated` priority only after every direct candidate has failed AVPlayer validation.
- Successful direct playback does not create an offline file. The Downloads tab changes only after an explicit download or a legacy playback fallback.
- Automatic next-item download prefetch is disabled; recommendation queue filling does not initiate downloads.

### PythonRunner priority queue

- **`.high` / `.userInitiated`** — play taps. Jumps the line.
- **`.low` / `.background`** — Download All, queue prefetch.
- Within priority: FIFO. Cannot preempt the currently-running yt-dlp (Python has no safe interrupt point).
- This is the fix for "user taps a video while a 50-item playlist Download All is in flight" — without the priority lane the user waits behind the entire batch.

### Network gate

- `wifiOnlyDownloads` setting checked via `NWPathMonitor` before every `ensureDownloaded` returns from queued state.

### Background URL session

- There is none. `BackgroundDownloadCoordinator` and the `BGProcessingTask` registration were
  removed in the 2026-09 security audit: nothing ever submitted a task to that session and the
  delegate dropped finished files on the floor. If background downloads are ever needed, build a
  persistent queue first; do not resurrect the old file.

### Security invariants (see SECURITY-AUDIT.md)

- `SecurityHardening.configureAtLaunch()` runs first in `AppEnvironment.init`. It locks
  `HTTPCookieStorage.shared` to `.never` (YouTubeKit uses `URLSession.shared`, whose jar is on
  disk), exports `SSL_CERT_FILE` → bundled `Resources/cacert.pem`, and moves the yt-dlp cache to
  `Library/Caches`.
- **Never** pass `--no-check-certificates` / `nocheckcertificate` to yt-dlp again.
- **Never** hand cookies to yt-dlp (`--cookies`, `cookiefile`). It made extraction worse and puts
  the session on disk.
- Diagnostic logs live in `Library/Application Support/Logs`, never `Documents`.
- Log URLs through `SecurityHardening.redactedForLog(_:)`; never `absoluteString`.
- `AppLog` redacts unannotated interpolations. Mark values `privacy: .public` explicitly.

### Cache limit

- `UserPreferences.downloadCacheLimitBytes` — when exceeded, oldest `DownloadedVideo` rows by `downloadedAt` get evicted along with their files.

---

## 11. SwiftData models

```swift
@Model class WatchHistoryEntry { videoID, title, channelName, thumbnailURL, watchedAt, lastPosition }
@Model class DownloadedVideo   { videoID, title, channelName, thumbnailData, fileURL, formatID, fileSize, downloadedAt }
@Model class FavoriteVideo     { videoID, title, channelName, thumbnailURL, savedAt }
@Model class FavoritePlaylist  { playlistID, title, thumbnailURL, savedAt }
@Model class SearchHistoryEntry { query, searchedAt }
```

`PlaybackQueueSnapshot` (originally planned) was not implemented — the queue is reconstructed from recommendations on each play.

**Writes go through `PersistenceWriter` (an `@ModelActor`).** Views and view models never block on SwiftData saves; they call `PersistenceWriter.shared.upsertFoo(...)` and fire-and-forget. The actor owns a background `ModelContext`, batches writes, and keeps the SQLite queue off the main thread. Direct `modelContext.insert(...)` on the main actor is fine for trivial inserts (e.g. one-shot user actions) but avoid loops or burst inserts there.

Preferences live in `UserDefaults` via a `@AppStorage`-backed `UserPreferences` type. Don't over-engineer with SwiftData for primitive flags.

---

## 12. Error handling rules

- Public service methods are `async throws`. Define `YouTubeServiceError`: `notAuthenticated`, `rateLimited`, `videoUnavailable`, `streamExtractionFailed`, `cookieExpired`, `network(Error)`, `decoding(Error)`, `unknown(Error)`.
- View models catch errors and translate to `@Published var errorState: ErrorState?` (or `var` on `@Observable`). Never let raw errors bubble to views.
- Show errors via the single `ErrorToastModifier`. Don't pepper alerts across screens.
- On `cookieExpired` / 401-equivalent: `SessionManager.handleExpiredSession()` wipes Keychain cookies + flips `AuthState`. Root view reacts and routes to Login.
- Stream extraction failure must always fall through to the next tier (see §7) before surfacing to the user.

---

## 13. Logging

Use the `AppLog` facade, which writes to `os.Logger` and optionally mirrors a rendered diagnostic file:

```swift
private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlaybackResolver")
log.info("Resolving \(videoID, privacy: .public) at quality \(quality.rawValue, privacy: .public)")
log.error("Stream extraction failed: \(error.localizedDescription, privacy: .public)")
```

- Cookie values, signed URLs, user emails: `privacy: .private` or omit entirely.
- Public IDs, response status, timing: `privacy: .public` is fine.
- Do not reconstruct file logs through `OSLogStore`; deferred interpolation can produce `<compose failure […]>`. `AppLog` mirrors already-rendered, privacy-filtered messages directly.
- **Do not log from SwiftUI body re-evaluation paths.** `DownloadManager.localFile(for:)` is called from `Menu` bodies that re-evaluate every player time tick; even a `log.debug` line floods the device log with hundreds of "miss" lines per second.

---

## 14. Localization

- `Localizable.xcstrings` (Apple String Catalog format), 236 keys, fully translated for **en / es / ru / fr / de**. `sourceLanguage: "en"`.
- Add new strings by using `String(localized:)` / `LocalizedStringKey` in code; Xcode's build-time extractor populates the catalog. After a build, open `Localizable.xcstrings` and translate any new `state: "new"` entries.
- **Non-translatable strings must never enter the catalog. Emit them with `Text(verbatim:)`, not a localizable `Text`.** A string whose entire content is format specifiers (`%@`, `%lld`, `%lld%%`), punctuation/symbols (`•`, `·`, `≈`, `,`), or brand names (`yt-dlp`, `freetube.io`) — with no actual words — has nothing to translate. The root cause is code: `Text("\(x) · \(n)%")` makes SwiftUI treat the literal as a `LocalizedStringKey`, so the extractor auto-adds junk keys like `%@ · %lld%%` on every build. Marking them `shouldTranslate: false` only suppresses *translation* — the key still gets re-added and clutters the catalog. **Fix at the source:** wrap these in `Text(verbatim: "...")` (for `.accessibilityLabel`, pass `Text(verbatim:)` explicitly). Then delete the orphaned keys from `Localizable.xcstrings`; once the code uses `verbatim`, the extractor won't recreate them. Keys removed this way (all now `verbatim` in code): `%@ · %lld%%` (FetchProbeView), `%lld%%` (FetchProbeView/DownloadsScreen), `≈ %@` (FetchProbeView), `• %@` (DownloadsScreen), `%lld %@ • %@` (DownloadsScreen), `%lld` (DownloadsScreen), `%@, %@` (VideoCard accessibility), `yt-dlp` (SettingsScreen header). When you write a new pure-format/symbol/brand string, reach for `Text(verbatim:)` up front so it never reaches the catalog.
- Pluralization uses Apple's CLDR plural rules through the catalog's variation editor.
- If you add a string that contains a literal source-file reference (e.g. an internal `ContentView` placeholder), use a clean user-facing value in the translation columns even if the key looks debug-ish.

---

## 15. Critical workarounds (read before refactoring `Core/`)

### 15.1 PythonRunner — Python-thread-pinning + serial drain

`PythonKit` + CPython assume one thread touches the interpreter — the thread that ran `PythonSupport.initialize()`. A plain `actor` rotates between cooperative-pool workers and Python crashes in `_PyInterpreterState_GET`. Fix: `PythonSerialExecutor` (a custom `SerialExecutor` backed by a serial `DispatchQueue`) — GCD reuses the same worker thread back-to-back for serial-queue jobs.

A plain serial actor isn't enough either: actor methods only guarantee one *body* at a time, but `await` lets another caller in. Fix: strict Task chaining through the `pump()` drain — new tickets enqueue, only one `pump` task drains at a time.

### 15.2 FFmpegRunner — ffmpeg C library serialization

`FFmpegSupport.ffmpeg(_:)` is not thread-safe. The `+faststart` post-pass walks global I/O buffers and crashes with `EXC_BAD_ACCESS` on concurrent calls. `setjmp`/`longjmp` in the Hook.m shim has undefined behavior across concurrent calls. Fix: `FFmpegRunner.shared.run(args)` serializes all ffmpeg calls through a chained `Task` FIFO. **Every** ffmpeg invocation goes through this actor.

### 15.3 yt-dlp's ffmpeg merger hangs on iOS

`subprocess.Popen.communicate` against ffmpeg never returns from inside the embedded Python on iOS — `longjmp` tears through the Python interpreter's stack. Fix: pass `--ffmpeg-location /dev/null/no-ffmpeg` to yt-dlp so it fails-fast at probe time instead of hanging. We mux ourselves with direct `FFmpegRunner` calls afterwards. Same reason `--postprocessor` flags must not request anything ffmpeg-backed inside yt-dlp.

### 15.4 yt-dlp PoT / n-cipher reality

YouTube has been enforcing Proof-of-Origin Tokens and rotating the `n`-parameter cipher in player.js on a 2–8-week cadence. Symptoms in logs:
- `n challenge solving failed: Some formats may be missing.`
- `Could not get n-parameter function.`
- `HTTP Error 403: Forbidden` on download.

**N-cipher: solved in-process via JavaScriptCore.** See §15.11 — `PythonJSBridge` routes current yt-dlp's `DenoJCP._run_js_runtime` directly through `JSContext` (with the older fake-`Popen` route retained as a compatibility fallback), and ships `yt-dlp-ejs` solver scripts in `Resources/`. The "n challenge solving failed" warnings should no longer fire for normal videos. The solver bundle (`yt-dlp-ejs 0.8.0`) needs re-pulling when YouTube rotates the cipher faster than yt-dlp's vendored regexes can match.

**PoT: still unsolved.** Proof-of-Origin Tokens require attesting to YouTube via a Play Integrity / DroidGuard / WidevineCDM challenge — not something a JS runtime alone can answer. Tier 3 streaming (HLS or direct progressive URL from `VideoInfosResponse`) remains the user-facing safety net for PoT-locked content (typically kids/family videos, some music labels).

### 15.5 AVQueuePlayer + `replaceCurrentItem` is a no-op when queue is empty

Don't use it. Use `removeAllItems()` + `insert(_:after:)` (see `loadItem`).

### 15.6 SourceKit "No such module 'FFmpegSupport' / 'Kingfisher'" warnings

Stale Xcode index. Real compiler links these fine; `xcodebuild` shows `BUILD SUCCEEDED`. Ignore. Clean Build Folder clears it.

### 15.7 Login `WKWebsiteDataStore` must be ephemeral

Using `.default()` reuses prior session cookies and captures stale ones. Use `.nonPersistent()`.

### 15.8 Cookie domain de-dup picks `.youtube.com`

When `.youtube.com` and `.google.com` versions of the same cookie are both present (post-login), YouTube only accepts the `.youtube.com` value. `CookieStore.dedupe` enforces this — don't simplify it to a length-based tiebreak.

### 15.9 `SubscriptionRegistry` exists because YouTubeKit can't parse subscribe state reliably

YouTubeKit's `subscribeStatus` doesn't follow `pageHeaderRenderer` entity-key indirection. We persist subscribe state in `UserDefaults` and reconcile on subscribe/unsubscribe.

### 15.10 Don't run heavy work from SwiftUI bodies

`FileManager.fileExists` inside `Menu` bodies (e.g. `localFile(for:)`) fires hundreds of times per second under the player view's KVO storm. The function itself is cheap; logging from it is not. Generally: anything called from a re-evaluating body should be allocation-free and log-free.

### 15.11 JavaScriptCore as yt-dlp's `deno` runtime

YouTube serves stream URLs whose `n` parameter is obfuscated by a transform function defined in player.js. yt-dlp's solver (the `EJS` framework, package `yt-dlp-ejs`) extracts that JS, builds a script, and pipes it to an external JS runtime — `deno`, `node`, `bun`, or `qjs`. No such binary exists on iOS. Without intercepting this, the user sees `n challenge solving failed` followed by 403s at the CDN.

We route yt-dlp's `deno` provider through `JavaScriptCore`. The bridge is **six pieces**, all installed by `PythonJSBridge.install()` at exactly one splice point inside our forked `freetube_yt_dlp(...)` entry — between `YtDlp()`'s init (which runs YoutubeDL-iOS's `injectFakePopen`) and `ydl.download` (which triggers JSC provider registration):

1. **`builtins.eval_js(code: str) -> str`** — Python-callable hook that runs JS via `JSEvaluator.evaluate(_:)`. PythonKit supplies this single argument directly; do not read `args[0]`, which indexes the Python string and evaluates only its first character. The caller's source is wrapped in an IIFE that installs its capture object on `globalThis.console` and captures both `console.log` and `console.info`. Current EJS emits its JSON result through the global `console.log`.

Download actions first resolve the same native source used by playback, then pass it to `NativeHLSDownloadService`. That service parses the HLS master/media playlists, chooses a quality-bounded native codec (AVC preferred, then HEVC) and the default audio rendition, downloads segments concurrently with `URLSession`, assembles tracks on disk, and uses the serialized in-process FFmpeg runner only for the final mux. Do not select advertised AV1/VP9 renditions merely because their bandwidth is highest: AVPlayer filters incompatible variants during adaptive playback, but a persisted single-rendition file loses that protection. Embedded yt-dlp does not participate in this primary transfer path. Page extraction remains a compatibility fallback and must not enable `formats=missing_pot`: those formats are intentionally filtered because they lack a required Proof-of-Origin token and produce HTTP 403 or throttled transfers.

2. **`yt_dlp_ejs` sys.modules shim** — yt-dlp gates the whole EJS path on `from yt_dlp.dependencies import yt_dlp_ejs as _has_ejs` being truthy. We synthesize three modules (`yt_dlp_ejs`, `.yt`, `.yt.solver`) in `sys.modules` with the package's exact API — `version`, `core()`, `lib()` — reading from our bundled `core.min.js` (the N/SIG solver, ~7 KB) and `lib.min.js` (meriyah + astring bundle, ~152 KB) via `EJSResources`. We also rebind `yt_dlp.dependencies.yt_dlp_ejs` after the fact in case it was imported before us.

3. **`DenoJsRuntime._info` monkey-patch** — yt-dlp normally spawns `deno --version` and parses stdout to populate `_js_runtimes['deno'].info`. We replace `_info` to return a supported `JsRuntimeInfo` without any subprocess call.

4. **Direct `DenoJCP._run_js_runtime` monkey-patch** — current yt-dlp exposes the complete EJS payload at this boundary. We pass it straight to `builtins.eval_js` and return the JSON result, avoiding the fragile subprocess/stdout emulation that produced empty output with yt-dlp 2026.08.19.

5. **Pop class compatibility monkey-patch (not `subprocess.Popen`)** — retained for older yt-dlp providers. YoutubeDL-iOS replaces `subprocess.Popen` with its ffmpeg-only `Pop` class at init time, so the bridge extends that existing class and intercepts only our fake deno path. Everything else falls through to the original `Pop`.

6. **`js_runtimes` ydl_opt** — even with the runtime detection stubbed, yt-dlp's `_js_runtimes` dict only gets populated from the `js_runtimes` ydl_opt. `FreeTubeYtDlp.swift` adds `ydl_opts["js_runtimes"] = {"deno": {"path": fakeDenoPath}}` so the dict has an entry to apply (3) to.

**Maintenance:** when YoutubeDL-iOS bumps its yt-dlp version, re-pull `yt-dlp-ejs` from PyPI to match (check upstream `vendor.HASHES`), update `EJSResources.version`, drop new `core.min.js`/`lib.min.js` into `Resources/`. yt-dlp validates major/minor version of the script against its embedded `_SCRIPT_VERSION`; mismatch silently disables the EJS path.

### 15.12 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` runs anything unannotated on main

This project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in both Debug and Release. Under that setting:

- A top-level `public func foo() async throws { ... }` is implicitly `@MainActor`.
- A top-level enum / struct / class with no isolation marker is implicitly `@MainActor`. Its static members inherit.
- `Task { ... }` (the `init` form) inherits caller isolation, which under default-MainActor is main — **even when created from inside a non-main `actor` body** like `PythonRunner`.

Symptom: a yt-dlp download stack shows up on Thread 1 (main) — `_ssl__SSLSocket_do_handshake` → many `_PyEval_EvalFrameDefault` → `ThrowingPythonObject.dynamicallyCall` → `freetube_yt_dlp` → `closure #1 in PythonRunner.pump()`. Main runloop is blocked for the entire download.

**Fix for new code that touches Python / SSL / JSCore:**
- Use `Task.detached(priority: .utility) { ... }` to dispatch, never plain `Task { }`. `.detached` is the explicit "do NOT inherit isolation" form.
- Mark top-level Python-touching async functions `public nonisolated func ...`.
- Mark enclosing enums / structs `nonisolated` so their static members aren't pulled to main either. `PythonJSBridge`, `JSEvaluator`, `EJSResources`, and `freetube_yt_dlp` all carry `nonisolated`.

This bit twice during the JS-bridge work — the obvious "wrap in `Task`" fix didn't help because the wrapping Task itself was `@MainActor`. Don't revert `Task.detached` back to `Task` without also auditing the surrounding isolation annotations.

---

## 16. Build priority (work top-down)

Current state of the implementation. Items marked ✓ are shipped.

- **P0 — MVP playback** ✓
  - YouTubeKit + YoutubeDL-iOS SPM setup
  - `HomeService`, `SearchService` (+ autocomplete), `VideoService`
  - Home screen, Search screen, Video detail screen
  - Three-tier playback resolver (yt-dlp / YouTubeKit / streaming HLS)
  - `PlayerStateManager`, mini player + full-screen popup (LNPopupUI)
  - Background audio + Now Playing + Remote Command Center
- **P1 — Account** ✓
  - Login (`WKWebView` ephemeral data store + Keychain)
  - `AccountService`, `SubscriptionService`, `HistoryService`
  - Subscriptions tab, Library tab (History / Playlists / Your videos / Subscriptions / Liked / Watch later)
  - Like / Dislike, Save-to-playlist sheet
  - Channel screen, Playlist screen
- **P2 — Engagement** ✓ (mostly)
  - `CommentService` (read + write + reply + rate)
  - `DownloadManager` with priority queue + cache limit
  - Queue management UI
  - PiP, AirPlay
  - CarPlay audio mode — not yet
- **P3 — Polish** (in flight)
  - Comment translation ✓
  - Localization en / es / ru / fr / de ✓
  - JavaScriptCore-based n-decoder ✓ (see §15.11 — `PythonJSBridge` fakes deno via JSCore; ships `yt-dlp-ejs` JS in `Resources/`)
  - Custom video controls beyond AVPlayerViewController — not in scope for v1

---

## 17. When to ask before doing

Stop and ask when:

- A request implies adding a dependency not on the locked stack.
- A request implies App Store distribution accommodations.
- A YouTubeKit response type doesn't map cleanly to the service layer in §6.
- A request asks Claude to handle cookies, tokens, or stream URLs in any persistence layer other than Keychain (cookies) or in-memory (URLs).
- A request would require building custom video player controls from scratch before the AVPlayerViewController-based v1 is shipped.
- A request asks to integrate with Chromecast, Google Cast, or any non-AirPlay casting (not in scope).
- A request asks to drop the iOS deployment target below 17.0 — that's not a config change, it's a SwiftData → CoreData + `@Observable` → `ObservableObject` refactor across ~30 files.

Do not ask before:

- Adding a new feature folder under `Features/`.
- Adding shared components under `UI/Components/`.
- Refactoring within a single file.
- Writing or extending tests.
- Adding `os.Logger` lines (outside of hot view-body paths — see §15.10).

---

## 18. Code style

- Four-space indentation, matching SwiftFormat default.
- Trailing closures only when there's exactly one closure parameter.
- `self.` only when required by closure capture rules.
- Prefer `let` over `var`. Mark types `final` unless designed for subclassing.
- Group `import` statements: stdlib first, Apple frameworks next, third-party last, each block separated by a blank line.
- Doc comments (`///`) on all public service methods, view models, and non-trivial types — especially anything that encodes a workaround like §15. Future-you will thank you.

---

## 19. Known limitations to communicate

If asked to "make it more robust" or "production-ready", point to these realities first instead of inventing solutions:

- YouTube can change its internal API at any time and silently break extraction. There is no SLA.
- Cookies expire (typically 1-2 weeks of inactivity); the user will need to re-login.
- N-cipher-locked content downloads in-process via the JSCore bridge (§15.11). PoT-locked content (Play Integrity attestation, not solvable by a JS runtime) still **cannot be downloaded** and falls through to tier 3 streaming. Kids/family content is the usual PoT offender.
- yt-dlp's HLS downloader needs ffmpeg, which is blocked by §15.3 — yt-dlp picking an HLS-only format fails on iOS. Tier 2/3 take over.
- IP-level rate limiting from YouTube can hit users on shared networks (CGNAT, VPN). No client-side fix.
- This codebase intentionally does not implement App Store evasion techniques. Sideload distribution is the assumption.
- Playback is started before AVPlayer reports `.readyToPlay` (§7), so the transport can sit in `.waitingToPlayAtSpecifiedRate` for a moment after the thumbnail is up. AVPlayer still decides when it has buffered enough to begin, so this brings the start forward to the earliest instant AVPlayer allows rather than overriding its judgement.
- HLS variant selection is bounded by `preferredQuality.heightCap` via `AVPlayerItem.preferredMaximumResolution`, but we don't pre-pick a variant — AVPlayer's adaptive bitrate logic still chooses freely below that ceiling, so the played resolution can sit under the user's setting on a weak connection.

---

## 20. When in doubt

Re-read sections 2, 6, 7, and 15. Most architectural questions are answered there. If still unclear, ask in the PR or commit message rather than guessing — the cost of asking is one round-trip; the cost of guessing wrong is a refactor.
