# Security audit — FreeTube iOS

Scope: the whole app target (`FreeTube/FreeTube`, 205 Swift files) plus the vendored
`FreeTubeStreamKit`, the pinned `b5i/YouTubeKit` and `kewlbear/YoutubeDL-iOS` sources, the Xcode
project settings and the CI workflows. Date: 2026-09-17, on `Gwal3n/freetube@87c2315`.

Primary question: **can the signed-in Google account leak?** — through cookies, the
`SAPISIDHASH` authorization header, disk, logs, backups, third-party hosts, or the ~2,000-site
"Link" tab that runs yt-dlp in-process.

Every finding below is fixed in this repository unless marked *accepted*.

---

## What the account material is and where it is allowed to be

| Material | Allowed location | Verified |
|---|---|---|
| Cookie header (`SAPISID`, `SID`, `HSID`, `SSID`, `APISID`, `LOGIN_INFO`, `__Secure-*`) | Keychain item `com.leshko.freetube.cookies`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not iCloud-synced, not in backups); in memory on `YouTubeModel.cookies` | ✓ `KeychainHelper`, `CookieStore`, `SessionManager` |
| `Authorization: SAPISIDHASH …` | Computed per request by YouTubeKit, never stored | ✓ `YouTubeModel.sendRequest` |
| Login WKWebView session | `.nonPersistent()` data store, torn down with the sheet | ✓ `LoginWebView.makeUIView` |

Cookie *values* are never logged — every log site prints name, domain and length only. Confirmed
by reading all 40 cookie-related log lines in `Core/Auth` and `Core/Networking`.

## Findings

### H1 — TLS verification disabled for every yt-dlp request  *(fixed)*

`DownloadManager` passed `--no-check-certificates` and `freetube_yt_dlp_extract_info` set
`nocheckcertificate = true`. This covered not only YouTube but every third-party site the Link
tab can be pointed at. Root cause: Python-iOS ships OpenSSL without a CA bundle on a reachable
path, so verification failed with `CERTIFICATE_VERIFY_FAILED` and the flag was the workaround.

Fix: `Resources/cacert.pem` (Mozilla CA bundle from curl.se, SHA-256
`f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9`, 121 roots) is bundled and
`SecurityHardening.configureAtLaunch()` exports `SSL_CERT_FILE` before Python starts. Python's
`ssl.SSLContext.load_default_certs()` honours it. Both flags are removed; a MITM now fails closed.

### H2 — Rotated Google session cookies persisted to disk by the shared cookie jar  *(fixed)*

`b5i/YouTubeKit` and `ChannelVideosFallbackService` send requests through `URLSession.shared`.
Its default configuration accepts `Set-Cookie` into `HTTPCookieStorage.shared`, which is
**on-disk** (`Library/Cookies/Cookies.binarycookies`) and part of device backups. InnerTube
responses rotate `__Secure-1PSIDTS`, `__Secure-3PSIDTS`, `SIDCC`, `__Secure-1PSIDCC`,
`__Secure-3PSIDCC` on nearly every call, so a signed-in user's current session identifiers were
being written outside the Keychain continuously. This directly contradicted the project rule that
cookies live in the Keychain only.

Fix: at launch `HTTPCookieStorage.shared.cookieAcceptPolicy = .never` and any cookies left by
earlier builds are deleted; `SessionManager.signOut()` purges again. The app manages the `Cookie`
header itself, so the jar has no legitimate job. Behaviour matches yt-dlp with a static cookie
file: Google keeps accepting the un-rotated values for weeks.

### M1 — yt-dlp verbose trace written to the user-visible `Documents` folder  *(fixed)*

`freetube_yt_dlp_extract_info` redirected Python `stdout`/`stderr` to `Documents/Logs/ytdlp-stderr.log`
unconditionally, with `verbose = true`. `UIFileSharingEnabled` exposes `Documents` in Finder and
the Files app, and the folder is backed up. Verbose extractor output contains the full signed
`googlevideo` URLs (client IP, expiry, PoT token) and the exact URL pasted into the Link tab.

Fix: the scratch file is created in `tmp/` with mode 0600 and deleted when the probe returns.
`verbose` is on only when the user has enabled "Save logs to file"; warnings/errors are kept.

### M2 — Diagnostic logs stored in `Documents`  *(fixed)*

`LogFileWriter` wrote `Documents/Logs/*.log`. Same exposure as M1, whenever the toggle is on.

Fix: logs now live in `Library/Application Support/Logs` (`SecurityHardening.diagnosticsDirectory`);
`Documents/Logs` from earlier builds is removed on first launch. Sharing through the Settings share
sheet still works.

### M3 — Full URLs logged during sign-in and streaming  *(fixed)*

`LoginWebView` logged every navigation URL, including `accounts.google.com` pages whose query
strings carry login-flow tokens (`TL=`, `continue=`). `HLSResourceLoaderDelegate` logged full
signed CDN URLs. Both were marked `privacy: .public`, so they appear in Console.app and
sysdiagnose, and in the diagnostics file when enabled.

Fix: `SecurityHardening.redactedForLog(_:)` trims to `scheme://host/path?…`.

### M4 — `AppLog` made every interpolation public by default  *(fixed)*

`AppLogMessage.appendInterpolation(_:)` (no privacy argument) appended the raw value and the
facade then emitted the whole line with `privacy: .public`. This inverted `os.Logger`'s default
(dynamic values are private unless opted in). Only three call sites relied on it, all counts.

Fix: unannotated interpolations render as `<private>`; the three sites now say `.public`.
Unit-tested in `SecurityHardeningTests`.

### M5 — yt-dlp auto-update executed unverified code  *(fixed)*

`YtDlpUpdater` fetched `releases/latest/download/yt-dlp` weekly through
`YoutubeDL.downloadPythonModule()` and moved whatever arrived into place. yt-dlp is Python source
executed **in-process** with the app's full sandbox access, so it is the most privileged input the
app has.

Fix: `YtDlpUpdater.downloadVerifiedModule()` downloads the release's `SHA2-256SUMS`, verifies the
zipapp's digest and refuses to install on mismatch. The first-run path is also routed through it
when no module is installed. (Same origin, same TLS — this is integrity against truncation and
on-path substitution, not a second trust root.)

### M6 — Dead helper that wrote cookies to a plaintext file  *(fixed)*

`DownloadManager.makeTemporaryCookiesFile()` serialised the Keychain header into a Netscape
`cookies.txt` in `tmp/`. Unused since 2026-05, but one call away from reintroducing a disk copy of
the session. Removed; the history is preserved in a comment explaining why cookies must never be
handed to yt-dlp (and why it made extraction worse).

### L1 — Unused camera permission string  *(fixed)*

`NSCameraUsageDescription` was declared with no camera code anywhere. Removed.

### L2 — Unused background-download scaffolding  *(fixed)*

`BackgroundDownloadCoordinator` created a background `URLSession` and registered a
`BGProcessingTask` on every launch, but nothing ever submitted a task to that session, its
`didFinishDownloadingTo` delegate only logged a TODO, and the BG task handler did nothing but
reschedule itself. Removed along with `BGTaskSchedulerPermittedIdentifiers` and the `fetch`
background mode; `audio` remains. Downloads run through yt-dlp / `NativeHLSDownloadService`, whose
behaviour is unchanged.

### L3 — yt-dlp cache under `Documents`  *(fixed)*

Python-iOS rewrites `HOME` to a path below `Documents`, so yt-dlp's `~/.cache/yt-dlp` was exposed
through file sharing. `XDG_CACHE_HOME` now points at `Library/Caches/python`.

### Accepted

- **`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`** — intentional so downloaded
  videos are reachable from the Files app. After M1/M2/L3, `Documents` contains only downloads and
  their xattr metadata.
- **Backup export** (`AppBackupService`) contains subscriptions, playlists, watch/search history,
  favourites and 33 preference keys (including `recentFetchURLs`). No cookies, tokens or account
  identity. It is a user-initiated export; documented here so nobody adds credentials to it.
- **SponsorBlock** — `sponsor.ajay.app` is queried by SHA-256 *prefix* of the video ID
  (`/api/skipSegments/<4 hex>`), the privacy-preserving mode of that API.
- **JavaScriptCore challenge solving** — YouTube's `player.js` fragments run in a bare `JSContext`
  (no network, no filesystem, no `console` until we define a capture stub). Acceptable sandbox.

## Third-party hosts contacted

`www.youtube.com`, `music.youtube.com` (Music tab; cookie header + `SAPISIDHASH` bound to that
origin, dedicated ephemeral session with cookie storage off), `accounts.google.com` (sign-in
only), `*.googlevideo.com` (media),
`i.ytimg.com` and the avatar hosts YouTube returns (thumbnails, via Kingfisher, no cookies), `sponsor.ajay.app` (hashed prefix, optional),
`github.com` (yt-dlp release + checksums, weekly). Plus whatever the user pastes into the Link
tab — which now goes through yt-dlp **with TLS verification and without cookies**.

Captions (`/youtubei/v1/player` as the IOS client and `/api/timedtext`) are fetched **without
cookies**: subtitles are public and the request must not be attributable to the account.

No analytics, crash reporting or telemetry SDK is linked.

## How to re-verify

```sh
# no TLS bypass anywhere
rg -n 'no-check-certificates|nocheckcertificate' FreeTube   # → comments only
# cookies never leave Keychain/memory
rg -n 'cookies\.txt|--cookies|cookiefile' FreeTube           # → comments only
# nothing logs a full URL
rg -n 'absoluteString.*privacy' FreeTube                    # → no results
```

Unit coverage: `FreeTubeTests/SecurityHardeningTests.swift`.
