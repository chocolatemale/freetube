# AGENTS.md — FreeTube iOS (chocolatemale fork)

Read `CLAUDE.md` for architecture and the locked stack. This file records the mistakes already
made in this repository so they are not made twice. **When you hit a new one, add it here in the
same commit as the fix.** A fix without the note is half a fix.

Upstreams: `leshkodev/freetube` (origin of the codebase, dormant since 2026-07) →
`Gwal3n/freetube` (`main` + `feature/swiftui-player-container`) → this fork. Remotes `leshkodev`
and `gwal3n` are configured in the local clone.

## Security invariants (see SECURITY-AUDIT.md for the why)

- `SecurityHardening.configureAtLaunch()` must stay the first line of `AppEnvironment.init`.
- Never pass `--no-check-certificates` / `nocheckcertificate` to yt-dlp. TLS works because
  `SSL_CERT_FILE` points at `Resources/cacert.pem`. If HTTPS from Python fails, the bundle is
  missing or stale — refresh it from https://curl.se/ca/cacert.pem and check the `.sha256`.
- Never hand cookies to yt-dlp. It drops the PoT-exempt clients and puts the session on disk.
- `HTTPCookieStorage.shared` is locked to `.never`. Do not "fix" a login problem by re-enabling it;
  YouTubeKit's `URLSession.shared` would write rotated Google session cookies to disk again.
- Log URLs through `SecurityHardening.redactedForLog(_:)`, never `absoluteString`.
- `AppLog` redacts unannotated interpolations. Write `\(value, privacy: .public)` on purpose.
- Diagnostics belong in `Library/Application Support/Logs` (or `tmp/`), never `Documents`
  (`UIFileSharingEnabled` exposes it and it is backed up).
- New third-party hosts need a line in SECURITY-AUDIT.md "Third-party hosts contacted".

## Build / CI pitfalls

- **Xcode 27 license.** `xcodebuild` and even `git` (when `DEVELOPER_DIR` points at Xcode.app)
  refuse to run until `sudo xcodebuild -license accept`. Do not export `DEVELOPER_DIR` in a
  shell you also use for git. Syntax-only checks work without Xcode: `xcrun swiftc -parse file`.
- **Xcode 27 + LNPopupController 4.5.9 cannot build locally out of the box.** The package's
  `Package.swift` derives header search paths from `Context.packageDirectory`, which Xcode 27
  reports differently, so every path comes out as `…/troller/LNPopupController/Private/…` and the
  ObjC target fails with `'LNPopupBarAppearanceChainProxy.h' file not found`. CI (Xcode 26.6) is
  unaffected. Local workaround until upstream fixes it: `chmod u+w` the manifest in
  `DerivedData/…/SourcePackages/checkouts/LNPopupController/Package.swift` and make
  `targetRelativePath` anchor on the `/LNPopupController/LNPopupController/Private` marker
  instead of replacing `packageBase.path`. Re-apply after any package re-resolution.
- **Do not put DerivedData under `/tmp`.** The `/tmp` → `/private/tmp` symlink makes clang see
  two spellings of the same path and header lookups fail. Use the default DerivedData location.
- **Pure-Foundation code can be type-checked and run on macOS** with the CommandLineTools
  `swiftc` (`MusicResponseParser` was developed this way against captured JSON). Anything
  importing SwiftUI/UIKit/PythonKit cannot.
- **Unit tests do run in the simulator** — the Python-iOS xcframework has an
  `ios-arm64_x86_64-simulator` slice. The 2026-09-05 CI failure that led Gwal3n to disable the
  test step was an ordinary compile error, not a linking limitation. Keep `tests.yml` separate
  from the IPA workflow so a red test never blocks an IPA.
- **GitHub Actions YAML `run: |` blocks**: every line, including embedded scripts, must keep the
  block indentation. Write helper scripts to `$RUNNER_TEMP` with an indented heredoc instead of
  `python3 -c '...'` spanning lines. Validate locally with `ruby -ryaml -e 'YAML.load_file(...)'`.
- Xcode's `PBXFileSystemSynchronizedRootGroup` means new files under `FreeTube/FreeTube` and
  `FreeTube/FreeTubeTests` are picked up automatically — including `Resources/*.pem` and
  `Fixtures/*.json`. Do not hand-edit `project.pbxproj` to add files.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on for both targets.** Every class without
  `nonisolated` is implicitly `@MainActor` and gets an *isolated deinit*. On the iOS 26.2 simulator
  under Xcode 27 the back-deploy shim for that deinit
  (`swift_task_deinitOnExecutorMainActorBackDeploy`) double-frees → SIGABRT
  ("pointer being freed was not allocated") the first time such an object is deallocated. The app
  never deallocates its singletons, so only unit tests saw it: `QueueManagerTests` crashed for
  months and Gwal3n disabled the whole test step instead. Model / data classes that tests create
  and drop must be `nonisolated` (as `QueueManager` now is). Diagnose this class of failure from
  the `.ips` frames the tests workflow prints, not by guessing at the test code.
- `HTTPCookieStorage.cookieAcceptPolicy` only governs cookies arriving through URL loading
  (`setCookies(_:for:mainDocumentURL:)`). `setCookie(_:)` bypasses it; a test that used it to
  prove the lockdown was wrong, not the lockdown.

## YouTube / InnerTube pitfalls

- `WEB_REMIX` (YouTube Music) needs an **origin-bound** `SAPISIDHASH` for
  `https://music.youtube.com`; YouTubeKit's `www.youtube.com` hash is rejected. See
  `MusicService.sapisidHash`.
- Anonymous `FEmusic_home` continuation tokens return an empty tab; signed-in ones page. Do not
  treat an empty continuation as an error.
- Search without `params` returns a `musicCardShelfRenderer` plus a run of single-item
  `itemSectionRenderer`s (fold them into one shelf). With a filter it returns one
  `musicShelfRenderer`. Card sub-rows carry `"Song • 5:38"` and imply the card's artist.
- Album track rows have no thumbnail of their own; use the header art. Album tracks come back as
  `MUSIC_VIDEO_TYPE_OMV` (videos), search songs as `MUSIC_VIDEO_TYPE_ATV`.
- `/next` for the radio queue must **not** carry `params: "wAEB8gECKAE%3D"`; with it YouTube
  returns a `musicQueueRenderer` without any `playlistPanelRenderer` (0 items). Send only
  `videoId`, `playlistId: RDAMVM<id>`, `isAudioOnly`.
- `googlevideo` progressive URLs are throttled to ~25 KB/s on one long connection. Download in
  10 MiB `Range` chunks like yt-dlp does (`NativeHLSDownloadService.downloadProgressive`): the
  same 5 MB file went from >40 s (unfinished) to 3.6 s. Never feed a progressive URL to the HLS
  parser — it reads the whole file as text and fails.
- **Captions need the `IOS` client.** `timedtext` URLs from the WEB player response (what
  YouTubeKit's watch-page scrape returns) answer with an empty HTTP 200 unless a PO token is
  attached; the `IOS` client's URLs serve full `fmt=json3` transcripts. `CaptionService` calls
  `/youtubei/v1/player` as IOS directly, without cookies.
- yt-dlp's EJS request must be sent with `"output_preprocessed": false` on iOS 27, otherwise
  JavaScriptCore → Swift → PythonKit hands back an empty string (`PythonJSBridge`).
- PythonKit's single-argument `PythonFunction` receives the argument itself, not a tuple;
  `args[0]` indexes the string and sends one character to the solver.

## Driving the UI without a screen

Debug builds honour launch arguments (`DebugLaunchOptions`), e.g.
`xcrun simctl launch <udid> com.leshko.freetube -FTInitialTab music -FTMusicSurface library`,
`-FTMusicBrowse MPREb_…`, `-FTMusicQuery "daft punk"`, `-FTMusicPlay <videoId>`,
`-FTMusicDownload <videoId>`. Pair with `xcrun simctl io <udid> screenshot` and
`xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "com.leshko.freetube"'`.
Xcode 27 ships no Simulator.app; the GUI is `Xcode.app/Contents/Applications/DeviceHub.app`.

## Product decisions worth knowing

- Settings is a sheet (gear in Library, ⌘,), not a tab: iPhone folds a sixth tab into "More".
- Music playback reuses `PlayerStateManager` with `isAudioOnlySession`; the flag must be passed
  through every internal `load(...)` (next/previous/queue tap) or a song silently becomes video.
- Music downloads are ordinary downloads tagged `DownloadMetadata.audioOnlyFormatID`; they show
  in both Downloads and Music › Library.
