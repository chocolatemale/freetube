import CryptoKit
import Foundation
import OSLog

/// YouTube Music (`WEB_REMIX`) InnerTube client. `b5i/YouTubeKit` does not model this client, so
/// the Music tab talks to `music.youtube.com/youtubei/v1` directly and hands the JSON to
/// `MusicResponseParser`.
///
/// Auth: the Keychain cookie header (via `YouTubeKitClient.cookies`) plus a `SAPISIDHASH`
/// computed for the **music.youtube.com** origin — the hash is origin-bound, so YouTubeKit's
/// `www.youtube.com` value would be rejected here. Signed-in requests unlock the personalised home
/// ("Quick picks", "Listen again", mixes), the library and history. Anonymous requests still get
/// charts and moods.
///
/// Network hygiene: a dedicated ephemeral `URLSession` with cookie handling **off** — the header
/// is set explicitly and `Set-Cookie` responses are discarded (see SECURITY-AUDIT.md H2).
protocol MusicServicing: Sendable {
    func page(browseID: String) async throws -> MusicPage
    func continuation(_ token: String, pageID: String, offset: Int) async throws -> (shelves: [MusicShelf], continuation: String?)
    func search(query: String, filter: MusicSearchFilter) async throws -> (shelves: [MusicShelf], continuation: String?)
    func radio(videoID: String, playlistID: String?) async throws -> [MusicItem]
}

final class MusicService: MusicServicing, @unchecked Sendable {
    static let shared = MusicService()

    private let client: YouTubeKitClient
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "MusicService")

    private static let origin = "https://music.youtube.com"
    private static let clientVersion = "1.20250915.01.00"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    init(client: YouTubeKitClient = .shared) {
        self.client = client
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicServicing

    func page(browseID: String) async throws -> MusicPage {
        let root = try await post("browse", body: ["browseId": browseID])
        let page = MusicResponseParser.page(browseID: browseID, from: root)
        log.info("[music] browse \(browseID, privacy: .public) → shelves=\(page.shelves.count, privacy: .public) tracks=\(page.tracks.count, privacy: .public)")
        return page
    }

    func continuation(_ token: String, pageID: String, offset: Int) async throws -> (shelves: [MusicShelf], continuation: String?) {
        let root = try await post("browse", body: ["continuation": token])
        return MusicResponseParser.continuationShelves(pageID: pageID, offset: offset, from: root)
    }

    func search(query: String, filter: MusicSearchFilter) async throws -> (shelves: [MusicShelf], continuation: String?) {
        var body: [String: Any] = ["query": query]
        if let params = filter.params { body["params"] = params }
        let root = try await post("search", body: body)
        let result = MusicResponseParser.searchShelves(from: root)
        log.info("[music] search filter=\(filter.rawValue, privacy: .public) → shelves=\(result.shelves.count, privacy: .public)")
        return result
    }

    /// "Up next" radio seeded from a track. `RDAMVM<videoId>` is the per-song mix; a playlist
    /// context keeps the queue inside that playlist instead.
    func radio(videoID: String, playlistID: String?) async throws -> [MusicItem] {
        var body: [String: Any] = [
            "videoId": videoID,
            "playlistId": playlistID ?? "RDAMVM\(videoID)",
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
        ]
        if playlistID == nil { body["params"] = "wAEB8gECKAE%3D" }
        let root = try await post("next", body: body)
        return MusicResponseParser.queue(from: root)
    }

    // MARK: - Transport

    private func post(_ endpoint: String, body: [String: Any]) async throws -> JSONNode {
        var payload = body
        payload["context"] = [
            "client": [
                "clientName": "WEB_REMIX",
                "clientVersion": Self.clientVersion,
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US",
                "platform": "DESKTOP"
            ],
            "user": ["lockedSafetyMode": false]
        ]

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")

        let cookies = client.cookies
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let auth = Self.sapisidHash(cookies: cookies, origin: Self.origin) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw YouTubeServiceError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw YouTubeServiceError.streamExtractionFailed }
        if http.statusCode == 401 || http.statusCode == 403 {
            log.notice("[music] HTTP \(http.statusCode, privacy: .public) on \(endpoint, privacy: .public) — treating as expired session")
            throw YouTubeServiceError.cookieExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            log.error("[music] HTTP \(http.statusCode, privacy: .public) on \(endpoint, privacy: .public)")
            throw YouTubeServiceError.network(NSError(domain: "MusicService", code: http.statusCode))
        }
        return JSONNode(try JSONSerialization.jsonObject(with: data))
    }

    /// `SAPISIDHASH <unix-seconds>_<sha1("<seconds> <SAPISID> <origin>")>`, the scheme every
    /// Google web property uses to bind a cookie session to a request origin.
    static func sapisidHash(cookies: String, origin: String, now: Date = .now) -> String? {
        let pairs = cookies.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sapisid = pairs.first(where: { $0.hasPrefix("SAPISID=") })?.dropFirst("SAPISID=".count)
            ?? pairs.first(where: { $0.hasPrefix("__Secure-3PAPISID=") })?.dropFirst("__Secure-3PAPISID=".count),
              !sapisid.isEmpty else { return nil }
        let seconds = Int(now.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(seconds) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(seconds)_\(hex)"
    }
}
