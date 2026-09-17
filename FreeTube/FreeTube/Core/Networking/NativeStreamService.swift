import Foundation
import OSLog

import FreeTubeStreamKit

/// Resolves short-lived YouTube playback URLs with alexeichhorn/YouTubeKit's local extractor.
/// The extractor's hosted remote fallback is deliberately disabled: all requests and cipher
/// processing happen on the device, and signed URLs are cached in memory for at most 30 minutes.
protocol NativeStreamServicing: Sendable {
    func resolve(video: Video, quality: VideoQuality) async throws -> NativeStreamResult
}

final class NativeStreamService: NativeStreamServicing, @unchecked Sendable {
    private let cache: StreamURLCache
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "NativeStreamService")

    init(cache: StreamURLCache = .shared) {
        self.cache = cache
    }

    /// Returns an HLS, progressive video, or audio-only URL suitable for `AVPlayer`.
    func resolve(video: Video, quality: VideoQuality) async throws -> NativeStreamResult {
        let videoID = video.id
        // Bump the audio-only key so a cached itag 140 DASH `m4a` (2× duration / silent
        // second half) cannot win over an HLS audio playlist on the next play.
        let cacheKey = quality == .audioOnly ? "native-audioOnly-v2" : "native-\(quality.rawValue)"
        if let cached = await cache.getEntry(videoID: videoID, formatID: cacheKey) {
            log.debug("Native stream cache hit for \(videoID, privacy: .public)")
            return NativeStreamResult(url: cached.url, storyboard: cached.storyboard)
        }

        let startedAt = Date()
        log.info("Resolving native stream for \(videoID, privacy: .public) at \(quality.rawValue, privacy: .public) live=\(video.isLive, privacy: .public)")
        let youtube = YouTube(videoID: videoID, methods: [.local])

        do {
            // HLS first, for live and on-demand alike. `livestreams` only reads `hlsManifestUrl`
            // off the InnerTube player response, so it shares the same round-trip `streams` needs
            // but — crucially — never runs the JavaScriptCore signature/n-parameter solver.
            //
            // That solver re-parses the entire ~2.5 MB player.js once per InnerTube client (twice
            // normally, three times when no progressive format turns up), which measured at ~4s of
            // the ~5.4s native resolution. In practice its output was then discarded and this very
            // HLS URL played instead, so the whole pass was dead weight.
            //
            // Audio-only still starts from that master, then prefers its default audio media
            // playlist. Playing the progressive itag 140 DASH `m4a` makes AVPlayer report about
            // twice the real length with a silent second half.
            if let hls = try await hlsManifestURL(from: youtube, videoID: videoID) {
                if quality == .audioOnly {
                    if let audio = try await audioPlaylistURL(from: hls, videoID: videoID) {
                        let storyboard = await storyboard(from: youtube, videoID: videoID)
                        await cache.set(videoID: videoID, formatID: cacheKey, url: audio, storyboard: storyboard)
                        log.info("Resolved native HLS audio playlist for \(videoID, privacy: .public) in \(Date().timeIntervalSince(startedAt), privacy: .public)s")
                        return NativeStreamResult(url: audio, storyboard: storyboard)
                    }
                    log.notice("Native HLS master had no audio rendition for \(videoID, privacy: .public); trying progressive audio")
                } else {
                    let storyboard = await storyboard(from: youtube, videoID: videoID)
                    await cache.set(videoID: videoID, formatID: cacheKey, url: hls, storyboard: storyboard)
                    log.info("Resolved native HLS for \(videoID, privacy: .public) in \(Date().timeIntervalSince(startedAt), privacy: .public)s")
                    return NativeStreamResult(url: hls, storyboard: storyboard)
                }
            }

            let streams = try await youtube.streams
            let selected: FreeTubeStreamKit.Stream?
            if quality == .audioOnly {
                selected = streams
                    .filterAudioOnly()
                    .filter(\.isNativelyPlayable)
                    .highestAudioBitrateStream()
            } else {
                let heightCap = quality.heightCap ?? 1080
                selected = streams
                    .filterVideoAndAudio()
                    .filter(\.isNativelyPlayable)
                    .filter { ($0.videoResolution ?? .max) <= heightCap }
                    .highestResolutionStream()
            }

            if let selected {
                let storyboard = await storyboard(from: youtube, videoID: videoID)
                await cache.set(videoID: videoID, formatID: cacheKey, url: selected.url, storyboard: storyboard)
                log.info("Resolved native progressive stream for \(videoID, privacy: .public) height=\(selected.videoResolution ?? 0, privacy: .public) audioCodec=\(String(describing: selected.audioCodec), privacy: .public) bitrate=\(selected.bitrate ?? 0, privacy: .public) averageBitrate=\(selected.averageBitrate ?? 0, privacy: .public) container=\(selected.fileExtension.rawValue, privacy: .public) in \(Date().timeIntervalSince(startedAt), privacy: .public)s")
                return NativeStreamResult(url: selected.url, storyboard: storyboard)
            }

            log.notice("Native extractor returned no playable stream for \(videoID, privacy: .public) after \(Date().timeIntervalSince(startedAt), privacy: .public)s")
            throw YouTubeServiceError.streamExtractionFailed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.notice("Native extraction failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
    }

    private func storyboard(from youtube: YouTube, videoID: String) async -> VideoStoryboard? {
        do {
            guard let storyboard = try await youtube.storyboard else {
                log.debug("Native player response contained no storyboard for \(videoID, privacy: .public)")
                return nil
            }
            let result = VideoStoryboard(
                specification: storyboard.specification,
                recommendedLevel: storyboard.recommendedLevel
            )
            log.info("Native storyboard \(result == nil ? "could not be decoded" : "resolved", privacy: .public) for \(videoID, privacy: .public)")
            return result
        } catch {
            log.notice("Native storyboard extraction failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetches an HLS master and returns its default audio media playlist when one exists.
    private func audioPlaylistURL(from masterURL: URL, videoID: String) async throws -> URL? {
        do {
            var request = URLRequest(url: masterURL)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return HLSMasterParser.preferredAudioURL(playlist: text, baseURL: masterURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.notice("Native HLS audio playlist probe failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads the player response's HLS manifest URL without triggering signature deciphering.
    ///
    /// Returns `nil` instead of throwing when the extractor can't produce one, so a video that
    /// genuinely has no HLS variant still falls through to progressive selection rather than
    /// failing the whole resolution. Cancellation is rethrown so a rapid video switch still
    /// unwinds immediately.
    private func hlsManifestURL(from youtube: YouTube, videoID: String) async throws -> URL? {
        do {
            return try await youtube.livestreams.first?.url
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.notice("Native HLS probe found nothing for \(videoID, privacy: .public); trying progressive selection")
            return nil
        }
    }
}
