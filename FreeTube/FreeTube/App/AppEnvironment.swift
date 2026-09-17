import SwiftUI
import OSLog

/// Shared singletons placed into the SwiftUI environment by `FreeTubeApp`.
/// Views observe these via `@Environment(PlayerStateManager.self)` etc.
@available(iOS 17.0, *)
@MainActor
final class AppEnvironment {
    let playerStateManager = PlayerStateManager()

    init() {
        // Security defaults come before anything that could touch the network or Python:
        // cookie-jar lockdown, CA bundle for embedded OpenSSL, cache paths. See
        // `SecurityHardening` and SECURITY-AUDIT.md.
        SecurityHardening.configureAtLaunch()
        // Touch `LogFileWriter.shared` next so the file-logging writer (if enabled)
        // captures every subsequent line in this init — audio session setup, remote
        // commands, BG task registration, and yt-dlp TTL refresh.
        _ = LogFileWriter.shared
        AudioSessionConfigurator.configure()
        RemoteCommandCenter.wire(to: playerStateManager)
        if let cutoff = UserPreferences().historyRetentionPolicy.cutoffDate() {
            Task { await PersistenceWriter.shared.clearWatchHistory(olderThan: cutoff) }
        }
        // Non-blocking weekly TTL check on the locally-cached yt-dlp Python module. If the
        // cached copy is older than 7 days, fetch the latest from GitHub Releases in the
        // background. Doesn't interfere with the next playback attempt — the download is
        // detached and the cached copy stays usable until the new one fully lands. See
        // `YtDlpUpdater` for the longer rationale.
        YtDlpUpdater.shared.refreshIfStale()
        #if DEBUG
        runJavaScriptCoreSmokeTest()
        #endif
    }

    #if DEBUG
    /// Phase 1 of the JS-runtime work plan: prove `JavaScriptCore` is wired correctly in our
    /// build and can evaluate the kinds of operations YouTube's n-cipher relies on (string
    /// methods, array methods, bitwise ops, IIFE-style functions). Logs pass/fail to the
    /// Console.app subsystem `com.leshko.freetube/JSEvaluator`. Remove or downgrade once the
    /// integration work is shipped.
    private func runJavaScriptCoreSmokeTest() {
        let log = AppLog(subsystem: "com.leshko.freetube", category: "JSEvaluator")

        struct Case { let name: String; let code: String; let expected: String }
        let cases: [Case] = [
            Case(name: "arithmetic",
                 code: "1 + 1",
                 expected: "2"),
            Case(name: "string reverse (IIFE)",
                 code: "(function(){ return 'hello'.split('').reverse().join(''); })()",
                 expected: "olleh"),
            Case(name: "array + bitwise (n-cipher-shaped)",
                 code: """
                 (function() {
                   var a = 'abc123'.split('');
                   var k = 7;
                   for (var i = 0; i < a.length; i++) {
                     a[i] = String.fromCharCode(a[i].charCodeAt(0) ^ k);
                   }
                   return a.join('');
                 })()
                 """,
                 expected: "fdd&47"),
            Case(name: "exception is captured",
                 code: "throw new Error('expected failure');",
                 expected: "<should throw>"),
        ]

        for c in cases {
            do {
                let result = try JSEvaluator.evaluate(c.code)
                if c.expected == "<should throw>" {
                    log.error("[smoke] \(c.name, privacy: .public) FAILED: expected exception, got '\(result, privacy: .public)'")
                } else if result == c.expected {
                    log.info("[smoke] \(c.name, privacy: .public) OK → '\(result, privacy: .public)'")
                } else {
                    log.error("[smoke] \(c.name, privacy: .public) FAILED: got '\(result, privacy: .public)' expected '\(c.expected, privacy: .public)'")
                }
            } catch {
                if c.expected == "<should throw>" {
                    log.info("[smoke] \(c.name, privacy: .public) OK (threw as expected): \(String(describing: error), privacy: .public)")
                } else {
                    log.error("[smoke] \(c.name, privacy: .public) FAILED (threw): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    #endif
}
