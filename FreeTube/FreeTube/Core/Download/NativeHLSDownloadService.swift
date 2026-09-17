import Foundation
import OSLog

/// Downloads a resolved HLS source without asking yt-dlp to re-extract YouTube.
///
/// The service deliberately owns only transport concerns: it parses the master/media playlists,
/// selects a bounded video rendition and the manifest's default audio rendition, downloads media
/// segments concurrently to a temporary directory, and performs one serialized FFmpeg remux. It
/// never persists signed URLs and never holds the complete media in memory.
@available(iOS 17.0, *)
nonisolated final class NativeHLSDownloadService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "NativeHLSDownload")

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        manifestURL: URL,
        destination: URL,
        maximumHeight: Int,
        audioOnly: Bool,
        concurrency: Int,
        progress: @escaping ProgressHandler
    ) async throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetube-hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let masterText = try await fetchText(manifestURL)
        let master = try Self.parseMaster(masterText, baseURL: manifestURL)

        let selections: [Rendition]
        if master.video.isEmpty {
            // The resolver may occasionally return a media playlist directly. It is expected to
            // contain both tracks; final validation rejects it if that assumption is false.
            selections = [Rendition(url: manifestURL, kind: audioOnly ? .audio : .combined)]
        } else if audioOnly {
            guard let audio = Self.preferredAudio(from: master.audio, groupID: nil) else {
                throw NativeHLSError.missingAudioRendition
            }
            selections = [Rendition(url: audio.url, kind: .audio)]
        } else {
            guard let video = Self.preferredVideo(from: master.video, maximumHeight: maximumHeight) else {
                throw NativeHLSError.missingVideoRendition
            }
            log.info("Selected HLS video height=\(video.height ?? 0, privacy: .public) bandwidth=\(video.bandwidth, privacy: .public) codecs=\(video.codecs, privacy: .public)")
            var chosen = [Rendition(url: video.url, kind: video.audioGroupID == nil ? .combined : .video)]
            if let groupID = video.audioGroupID {
                guard let audio = Self.preferredAudio(from: master.audio, groupID: groupID) else {
                    throw NativeHLSError.missingAudioRendition
                }
                chosen.append(Rendition(url: audio.url, kind: .audio))
                log.info("Selected default HLS audio language=\(audio.language ?? "unspecified", privacy: .public) name=\(audio.name, privacy: .public)")
            }
            selections = chosen
        }

        var prepared: [(rendition: Rendition, playlist: MediaPlaylist)] = []
        for rendition in selections {
            let text = rendition.url == manifestURL && master.video.isEmpty
                ? masterText
                : try await fetchText(rendition.url)
            let playlist = try Self.parseMedia(text, baseURL: rendition.url)
            log.info("Parsed HLS \(rendition.kind.label, privacy: .public) playlist resources=\(playlist.resources.count, privacy: .public)")
            prepared.append((rendition, playlist))
        }

        let totalSegments = prepared.reduce(0) { $0 + $1.playlist.resources.count }
        guard totalSegments > 0 else { throw NativeHLSError.emptyMediaPlaylist }
        let tracker = ProgressTracker(total: totalSegments, handler: progress)

        var outputs: [RenditionKind: URL] = [:]
        for (index, item) in prepared.enumerated() {
            let trackDirectory = workDirectory.appendingPathComponent("track-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            let pieces = try await downloadResources(
                item.playlist.resources,
                into: trackDirectory,
                concurrency: max(1, min(16, concurrency)),
                tracker: tracker
            )
            let trackExtension = item.playlist.hasInitializationSegment ? "mp4" : "ts"
            let trackURL = workDirectory.appendingPathComponent("track-\(index).\(trackExtension)")
            try Self.concatenate(pieces, to: trackURL)
            outputs[item.rendition.kind] = trackURL
        }

        try? FileManager.default.removeItem(at: destination)
        let exit: Int32
        if audioOnly, let audio = outputs[.audio] ?? outputs[.combined] {
            exit = await FFmpegRunner.shared.run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
                "-i", audio.path, "-vn", "-c:a", "copy", destination.path
            ])
        } else if let combined = outputs[.combined] {
            exit = await FFmpegRunner.shared.run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
                "-i", combined.path, "-map", "0:v:0?", "-map", "0:a:0?",
                "-c", "copy", "-movflags", "+faststart", destination.path
            ])
        } else if let video = outputs[.video], let audio = outputs[.audio] {
            exit = await FFmpegRunner.shared.run([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning",
                "-i", video.path, "-i", audio.path,
                "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
                "-movflags", "+faststart", destination.path
            ])
        } else {
            throw NativeHLSError.missingTracks
        }
        guard exit == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw NativeHLSError.muxFailed(exit)
        }
        progress(1)
    }

    // MARK: - Progressive sources

    /// True when the resolver handed back a single media file (the audio-only path returns a
    /// progressive `videoplayback` URL) rather than an HLS playlist. Decided from the URL so no
    /// bytes are fetched just to find out.
    static func isProgressiveSource(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".m3u8") || path.contains("/manifest/") { return false }
        let mime = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "mime" }?.value?.lowercased() ?? ""
        if mime.contains("mpegurl") { return false }
        return path.contains("/videoplayback") || !mime.isEmpty
    }

    /// Downloads a progressive file to `destination` in 10 MiB ranged requests — the same shape
    /// yt-dlp uses for `googlevideo`, whose CDN throttles a single long-lived connection to a
    /// crawl but serves bounded ranges at full speed. Each chunk is appended to disk as it lands;
    /// an expired signed URL surfaces as an authorization failure the caller can retry.
    func downloadProgressive(
        _ source: URL,
        to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let chunk: Int64 = 10 * 1024 * 1024
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var total: Int64 = -1
        repeat {
            try Task.checkCancellation()
            var request = URLRequest(url: source)
            request.timeoutInterval = 60
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let http = response as? HTTPURLResponse else { throw NativeHLSError.incompleteTransfer }
            if total < 0 {
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalText = contentRange.split(separator: "/").last,
                   let parsed = Int64(totalText) {
                    total = parsed
                } else if http.statusCode == 200 {
                    // Server ignored the range and sent everything.
                    total = Int64(data.count)
                } else {
                    throw NativeHLSError.incompleteTransfer
                }
            }
            guard !data.isEmpty else { throw NativeHLSError.incompleteTransfer }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if total > 0 { progress(min(0.99, Double(offset) / Double(total))) }
        } while offset < total

        if offset != total {
            log.error("progressive download incomplete: wrote=\(offset, privacy: .public) expected=\(total, privacy: .public)")
            throw NativeHLSError.incompleteTransfer
        }
        progress(1)
    }

    // MARK: - Networking

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw NativeHLSError.invalidPlaylist
        }
        return text
    }

    private func downloadResources(
        _ resources: [MediaResource],
        into directory: URL,
        concurrency: Int,
        tracker: ProgressTracker
    ) async throws -> [URL] {
        let session = self.session
        let downloadOne: @Sendable (Int) async throws -> (Int, URL) = { index in
            let resource = resources[index]
            let target = directory.appendingPathComponent(String(format: "%06d.part", index))
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    try Task.checkCancellation()
                    var request = URLRequest(url: resource.url)
                    request.timeoutInterval = 30
                    if let range = resource.byteRange {
                        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                    }
                    let (temporary, response) = try await session.download(for: request)
                    try Self.validate(response)
                    if resource.byteRange != nil,
                       (response as? HTTPURLResponse)?.statusCode != 206 {
                        throw NativeHLSError.rangeIgnored
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    return (index, target)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    if attempt < 3 {
                        try await Task.sleep(for: .milliseconds(250 * attempt))
                    }
                }
            }
            throw lastError ?? NativeHLSError.segmentFailed(index)
        }
        return try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var nextIndex = 0
            var completed: [(Int, URL)] = []

            while nextIndex < min(concurrency, resources.count) {
                let index = nextIndex
                group.addTask { try await downloadOne(index) }
                nextIndex += 1
            }
            while let result = try await group.next() {
                completed.append(result)
                await tracker.completedOne()
                if nextIndex < resources.count {
                    let index = nextIndex
                    group.addTask { try await downloadOne(index) }
                    nextIndex += 1
                }
            }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NativeHLSError.http(status)
        }
    }

    static func isAuthorizationFailure(_ error: Error) -> Bool {
        guard let nativeError = error as? NativeHLSError else { return false }
        switch nativeError {
        case .http(401), .http(403): return true
        default: return false
        }
    }

    // MARK: - Playlist parsing

    private static func parseMaster(_ text: String, baseURL: URL) throws -> MasterPlaylist {
        let lines = text.components(separatedBy: .newlines)
        var video: [VideoRendition] = []
        var audio: [AudioRendition] = []
        var pendingStream: [String: String]?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attributes["TYPE"] == "AUDIO",
                      let uri = attributes["URI"],
                      let url = resolve(uri, relativeTo: baseURL) else { continue }
                audio.append(AudioRendition(
                    url: url,
                    groupID: attributes["GROUP-ID"] ?? "",
                    name: attributes["NAME"] ?? attributes["LANGUAGE"] ?? "Audio",
                    language: attributes["LANGUAGE"],
                    isDefault: attributes["DEFAULT"] == "YES",
                    isAutoSelect: attributes["AUTOSELECT"] == "YES"
                ))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStream = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#"), let attributes = pendingStream {
                pendingStream = nil
                guard let url = resolve(line, relativeTo: baseURL) else { continue }
                let resolution = attributes["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) }
                let bandwidth = Int(attributes["AVERAGE-BANDWIDTH"] ?? attributes["BANDWIDTH"] ?? "") ?? 0
                video.append(VideoRendition(
                    url: url,
                    height: resolution,
                    bandwidth: bandwidth,
                    audioGroupID: attributes["AUDIO"],
                    codecs: attributes["CODECS"] ?? ""
                ))
            }
        }
        return MasterPlaylist(video: video, audio: audio)
    }

    private static func parseMedia(_ text: String, baseURL: URL) throws -> MediaPlaylist {
        var resources: [MediaResource] = []
        var pendingRange: ClosedRange<Int64>?
        var nextImplicitOffset: Int64 = 0
        var hasInitializationSegment = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attributes["URI"], let url = resolve(uri, relativeTo: baseURL) else {
                    throw NativeHLSError.invalidPlaylist
                }
                let range = attributes["BYTERANGE"].flatMap { parseByteRange($0, implicitOffset: 0).range }
                resources.append(MediaResource(url: url, byteRange: range))
                hasInitializationSegment = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                let parsed = parseByteRange(value, implicitOffset: nextImplicitOffset)
                pendingRange = parsed.range
                nextImplicitOffset = parsed.nextOffset
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let url = resolve(line, relativeTo: baseURL) else {
                    throw NativeHLSError.invalidPlaylist
                }
                resources.append(MediaResource(url: url, byteRange: pendingRange))
                pendingRange = nil
            }
        }
        return MediaPlaylist(resources: resources, hasInitializationSegment: hasInitializationSegment)
    }

    private static func preferredVideo(from renditions: [VideoRendition], maximumHeight: Int) -> VideoRendition? {
        // AVPlayer filters incompatible variants while streaming a master playlist. Once we pick
        // and persist one rendition ourselves, that safety net is gone. Restrict downloads to
        // codecs with broad native iOS support: AVC first, then HEVC. AV1/VP9 can appear as the
        // highest-bandwidth 1080p rendition but produce a file with valid tracks/duration that
        // older devices still report as `isPlayable == false`.
        let compatible = renditions.filter { codecPreference($0.codecs) > 0 }
        guard !compatible.isEmpty else { return nil }
        let withinCap = compatible.filter { ($0.height ?? Int.max) <= maximumHeight }
        return (withinCap.isEmpty ? compatible : withinCap).max {
            let lhsHeight = $0.height ?? 0
            let rhsHeight = $1.height ?? 0
            if lhsHeight != rhsHeight { return lhsHeight < rhsHeight }
            let lhsCodec = codecPreference($0.codecs)
            let rhsCodec = codecPreference($1.codecs)
            if lhsCodec != rhsCodec { return lhsCodec < rhsCodec }
            return $0.bandwidth < $1.bandwidth
        }
    }

    /// Higher is preferred. An empty codec list is retained as a last resort because some valid
    /// HLS producers omit `CODECS`; explicitly advertised AV1/VP9 is rejected for offline files.
    private static func codecPreference(_ codecs: String) -> Int {
        let value = codecs.lowercased()
        if value.contains("avc1") || value.contains("avc3") { return 3 }
        if value.contains("hvc1") || value.contains("hev1") { return 2 }
        if value.isEmpty { return 1 }
        return 0
    }

    private static func preferredAudio(from renditions: [AudioRendition], groupID: String?) -> AudioRendition? {
        let group = groupID.map { id in renditions.filter { $0.groupID == id } } ?? renditions
        let pool = group.isEmpty ? renditions : group
        return pool.first { $0.isDefault && !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? pool.first { $0.isDefault }
            ?? pool.first { $0.isAutoSelect && !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? pool.first { !$0.name.localizedCaseInsensitiveContains("dubbed") }
            ?? pool.first
    }

    private static func parseAttributes(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        var start = input.startIndex
        var inQuotes = false
        var pieces: [Substring] = []
        for index in input.indices {
            if input[index] == "\"" { inQuotes.toggle() }
            if input[index] == ",", !inQuotes {
                pieces.append(input[start..<index])
                start = input.index(after: index)
            }
        }
        pieces.append(input[start...])
        for piece in pieces {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces)
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func resolve(_ value: String, relativeTo baseURL: URL) -> URL? {
        URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private static func parseByteRange(_ value: String, implicitOffset: Int64) -> (range: ClosedRange<Int64>?, nextOffset: Int64) {
        let pieces = value.split(separator: "@", maxSplits: 1)
        guard let length = Int64(pieces.first ?? ""), length > 0 else { return (nil, implicitOffset) }
        let start = pieces.count == 2 ? (Int64(pieces[1]) ?? implicitOffset) : implicitOffset
        let end = start + length - 1
        return (start...end, end + 1)
    }

    private static func concatenate(_ files: [URL], to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for file in files {
            let input = try FileHandle(forReadingFrom: file)
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try output.write(contentsOf: data)
            }
            try input.close()
        }
        try output.synchronize()
    }

    private actor ProgressTracker {
        private let total: Int
        private let handler: NativeHLSDownloadService.ProgressHandler
        private var completed = 0

        init(total: Int, handler: @escaping NativeHLSDownloadService.ProgressHandler) {
            self.total = total
            self.handler = handler
        }

        func completedOne() {
            completed += 1
            handler(Double(completed) / Double(total))
        }
    }

    private struct MasterPlaylist {
        let video: [VideoRendition]
        let audio: [AudioRendition]
    }

    private struct VideoRendition {
        let url: URL
        let height: Int?
        let bandwidth: Int
        let audioGroupID: String?
        let codecs: String
    }

    private struct AudioRendition {
        let url: URL
        let groupID: String
        let name: String
        let language: String?
        let isDefault: Bool
        let isAutoSelect: Bool
    }

    private struct Rendition {
        let url: URL
        let kind: RenditionKind
    }

    private enum RenditionKind: Hashable {
        case video
        case audio
        case combined

        var label: String {
            switch self {
            case .video: return "video"
            case .audio: return "audio"
            case .combined: return "combined"
            }
        }
    }

    private struct MediaPlaylist {
        let resources: [MediaResource]
        let hasInitializationSegment: Bool
    }

    private struct MediaResource: Sendable {
        let url: URL
        let byteRange: ClosedRange<Int64>?
    }

    private enum NativeHLSError: LocalizedError {
        case incompleteTransfer
        case invalidPlaylist
        case missingVideoRendition
        case missingAudioRendition
        case emptyMediaPlaylist
        case missingTracks
        case segmentFailed(Int)
        case http(Int)
        case muxFailed(Int32)
        case rangeIgnored

        var errorDescription: String? {
            switch self {
            case .incompleteTransfer: return "The download ended before the file was complete."
            case .invalidPlaylist: return "The HLS playlist was invalid."
            case .missingVideoRendition: return "The HLS playlist contained no video rendition."
            case .missingAudioRendition: return "The HLS playlist contained no audio rendition."
            case .emptyMediaPlaylist: return "The HLS media playlist contained no segments."
            case .missingTracks: return "The downloaded HLS tracks were incomplete."
            case .segmentFailed(let index): return "HLS segment \(index) could not be downloaded."
            case .http(let status): return "The HLS server returned HTTP \(status)."
            case .muxFailed(let exit): return "The downloaded HLS tracks could not be combined (\(exit))."
            case .rangeIgnored: return "The HLS server ignored a required byte range."
            }
        }
    }
}
