import Foundation
import OSLog

/// Process-wide security defaults. Runs once, first thing in `AppEnvironment.init`, before any
/// networking or Python work can happen.
///
/// Each step closes a concrete gap found in the 2026-09 audit (see `SECURITY-AUDIT.md`):
///
/// 1. **Shared cookie jar → never persist.** `b5i/YouTubeKit` and our raw-HTTP fallbacks go
///    through `URLSession.shared`, whose default configuration accepts `Set-Cookie` headers into
///    `HTTPCookieStorage.shared` — an *on-disk* store (`Library/Cookies/Cookies.binarycookies`,
///    included in device backups). Every InnerTube response rotates account session cookies
///    (`__Secure-1PSIDTS`, `__Secure-3PSIDTS`, `SIDCC`, …), so without this the Google session
///    quietly leaked out of the Keychain onto disk. The app manages the `Cookie` header itself,
///    so the jar has no legitimate job: reject everything and purge whatever earlier builds left.
/// 2. **TLS verification for embedded Python.** Python-iOS ships OpenSSL without a CA bundle on
///    a path it can find, which is why earlier builds passed `--no-check-certificates` to yt-dlp
///    for *every* request — including the Link tab's arbitrary third-party sites. We bundle the
///    Mozilla CA bundle (`Resources/cacert.pem`, from curl.se) and point OpenSSL at it through
///    `SSL_CERT_FILE`, which Python's `ssl.SSLContext.load_default_certs()` honours. The flag is
///    gone; a MITM now fails closed instead of silently succeeding.
/// 3. **yt-dlp cache out of `Documents`.** Python-iOS rewrites `HOME` to a path under `Documents`
///    (see `AppDirectories`), so yt-dlp's `~/.cache/yt-dlp` landed in the folder that
///    `UIFileSharingEnabled` exposes to Finder / the Files app. `XDG_CACHE_HOME` moves it to
///    `Library/Caches`, which the system may also reclaim under pressure — correct for a cache.
nonisolated enum SecurityHardening {
    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "Security")

    /// Idempotent; safe to call more than once but only the first call does work.
    static func configureAtLaunch() {
        _ = configured
    }

    private static let configured: Bool = {
        lockDownSharedCookieJar()
        configurePythonEnvironment()
        return true
    }()

    // MARK: - 1. Shared cookie jar

    private static func lockDownSharedCookieJar() {
        let jar = HTTPCookieStorage.shared
        jar.cookieAcceptPolicy = .never
        let stale = jar.cookies ?? []
        for cookie in stale {
            jar.deleteCookie(cookie)
        }
        if !stale.isEmpty {
            log.notice("[security] purged \(stale.count, privacy: .public) cookies persisted by earlier builds")
        }
    }

    /// Called from `SessionManager.signOut()` as belt and braces: `cookieAcceptPolicy = .never`
    /// should already keep the jar empty, but a sign-out must leave no session material behind
    /// regardless of ordering.
    static func purgeSharedCookieJar() {
        let jar = HTTPCookieStorage.shared
        for cookie in jar.cookies ?? [] {
            jar.deleteCookie(cookie)
        }
    }

    // MARK: - 2 + 3. Embedded Python environment

    /// Path of the bundled Mozilla CA bundle, or `nil` if the resource is missing from the build.
    static var bundledCACertificatePath: String? {
        Bundle.main.path(forResource: "cacert", ofType: "pem")
    }

    private static func configurePythonEnvironment() {
        if let pem = bundledCACertificatePath {
            setenv("SSL_CERT_FILE", pem, 1)
            log.info("[security] SSL_CERT_FILE → bundled Mozilla CA bundle")
        } else {
            // Fail loudly rather than silently: without a CA bundle every yt-dlp HTTPS request
            // will now fail with CERTIFICATE_VERIFY_FAILED, which is the correct behaviour — but
            // it means the build is broken and should not ship.
            log.fault("[security] cacert.pem missing from bundle — yt-dlp HTTPS will fail closed")
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let pythonCache = caches.appendingPathComponent("python", isDirectory: true)
        try? FileManager.default.createDirectory(at: pythonCache, withIntermediateDirectories: true)
        setenv("XDG_CACHE_HOME", pythonCache.path, 1)
    }

    // MARK: - Diagnostics directory

    /// Where diagnostic logs live. Deliberately *not* `Documents`: that folder is exposed through
    /// `UIFileSharingEnabled` and included in device backups. `Application Support` is private to
    /// the app but still shareable on demand via the Settings share sheet.
    static let diagnosticsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Trims a URL to `scheme://host/path` for logging. Query strings on Google sign-in pages carry
    /// login-flow tokens (`TL=`, `continue=` …) and signed CDN URLs carry the client IP plus the
    /// proof-of-origin token; neither belongs in the unified log or a shareable diagnostics file.
    static func redactedForLog(_ url: URL?) -> String {
        guard let url else { return "?" }
        var text = url.scheme.map { "\($0)://" } ?? ""
        text += url.host ?? "?"
        if let port = url.port { text += ":\(port)" }
        text += url.path
        if url.query != nil { text += "?…" }
        return text
    }
}
