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
- yt-dlp's EJS request must be sent with `"output_preprocessed": false` on iOS 27, otherwise
  JavaScriptCore → Swift → PythonKit hands back an empty string (`PythonJSBridge`).
- PythonKit's single-argument `PythonFunction` receives the argument itself, not a tuple;
  `args[0]` indexes the string and sends one character to the solver.

## Product decisions worth knowing

- Settings is a sheet (gear in Library, ⌘,), not a tab: iPhone folds a sixth tab into "More".
- Music playback reuses `PlayerStateManager` with `isAudioOnlySession`; the flag must be passed
  through every internal `load(...)` (next/previous/queue tap) or a song silently becomes video.
- Music downloads are ordinary downloads tagged `DownloadMetadata.audioOnlyFormatID`; they show
  in both Downloads and Music › Library.
