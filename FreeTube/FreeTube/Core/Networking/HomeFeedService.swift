import Foundation
import OSLog

/// Signed-in YouTube Home: the same `FEwhat_to_watch` browse the official app renders, with its
/// topic chips, recommended videos and shelves, and infinite scroll via continuations.
///
/// Raw InnerTube rather than YouTubeKit's `HomeScreenResponse` because the chip bar and the
/// shelves are not modelled there. Auth is the Keychain cookie header plus an origin-bound
/// `SAPISIDHASH` for `www.youtube.com`; the session is ephemeral with cookie storage off
/// (SECURITY-AUDIT.md H2). Anonymous requests return only a "sign in" nudge, which is why the
/// Home tab falls back to the local subscription feed when signed out.
protocol HomeFeedServicing: Sendable {
    func home(chipParams: String?) async throws -> HomeFeedPage
    func more(continuation: String) async throws -> HomeFeedPage
}

final class HomeFeedService: HomeFeedServicing, @unchecked Sendable {
    private let client: YouTubeKitClient
    private let session: URLSession
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "HomeFeedService")

    private static let origin = "https://www.youtube.com"
    private static let clientVersion = "2.20260213.01.00"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.2 Safari/605.1.15"

    init(client: YouTubeKitClient = .shared) {
        self.client = client
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func home(chipParams: String?) async throws -> HomeFeedPage {
        var body: [String: Any] = ["browseId": "FEwhat_to_watch"]
        if let chipParams { body["params"] = chipParams }
        let root = try await post(body)
        let page = HomeFeedParser.page(from: root)
        log.info("[home] chips=\(page.chips.count, privacy: .public) items=\(page.items.count, privacy: .public) more=\(page.continuation != nil, privacy: .public)")
        return page
    }

    func more(continuation: String) async throws -> HomeFeedPage {
        let root = try await post(["continuation": continuation])
        let page = HomeFeedParser.page(from: root)
        log.info("[home] continuation → items=\(page.items.count, privacy: .public) more=\(page.continuation != nil, privacy: .public)")
        return page
    }

    private func post(_ body: [String: Any]) async throws -> JSONNode {
        var payload = body
        payload["context"] = [
            "client": [
                "clientName": "WEB",
                "clientVersion": Self.clientVersion,
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "platform": "DESKTOP",
                "userAgent": Self.userAgent + ",gzip(gfe)",
                "visitorData": client.visitorData
            ],
            "user": ["lockedSafetyMode": false],
            "request": ["useSsl": true]
        ]
        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/browse?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if !client.visitorData.isEmpty {
            request.setValue(client.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let cookies = client.cookies
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let auth = InnerTubeAuth.sapisidHash(cookies: cookies, origin: Self.origin) {
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
        if http.statusCode == 401 || http.statusCode == 403 { throw YouTubeServiceError.cookieExpired }
        guard (200..<300).contains(http.statusCode) else {
            throw YouTubeServiceError.network(NSError(domain: "HomeFeedService", code: http.statusCode))
        }
        return JSONNode(try JSONSerialization.jsonObject(with: data))
    }
}

/// Structural parser for `FEwhat_to_watch` and its continuations. It walks the tree for the
/// renderers that matter — `chipCloudChipRenderer` inside `feedFilterChipBarRenderer`,
/// `videoRenderer` inside `richItemRenderer`, `richShelfRenderer`, `continuationItemRenderer` —
/// so the exact wrapper (initial tab, `appendContinuationItemsAction`,
/// `reloadContinuationItemsCommand`) does not matter.
enum HomeFeedParser {
    static func page(from root: JSONNode) -> HomeFeedPage {
        var chips: [HomeFeedChip] = []
        var items: [HomeFeedItem] = []
        var continuation: String?
        var seenVideoIDs = Set<String>()

        func visit(_ node: JSONNode) {
            guard let dict = node.value as? [String: Any] else {
                if let array = node.value as? [Any] { array.forEach { visit(JSONNode($0)) } }
                return
            }
            if dict["feedFilterChipBarRenderer"] != nil {
                var seen = Set<String>()
                chips = node["feedFilterChipBarRenderer"]["contents"].array.compactMap(chip)
                    .filter { seen.insert($0.id).inserted }
                return
            }
            if dict["richItemRenderer"] != nil {
                if let video = contentVideo(node["richItemRenderer"]["content"]),
                   !seenVideoIDs.contains(video.id) {
                    seenVideoIDs.insert(video.id)
                    items.append(.video(video))
                }
                return
            }
            if dict["richSectionRenderer"] != nil {
                if let shelf = shelf(from: node["richSectionRenderer"]["content"]) {
                    items.append(.shelf(shelf))
                }
                return
            }
            if dict["continuationItemRenderer"] != nil {
                continuation = node["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string
                    ?? node["continuationItemRenderer"]["continuationEndpoint"]["commandExecutorCommand"]["commands"].array
                        .compactMap { $0["continuationCommand"]["token"].string }.first
                    ?? continuation
                return
            }
            for (key, value) in dict where key != "trackingParams" && key != "accessibility" {
                visit(JSONNode(value))
            }
        }
        visit(root["contents"])
        visit(root["onResponseReceivedActions"])
        visit(root["onResponseReceivedEndpoints"])
        visit(root["header"])
        return HomeFeedPage(chips: chips, items: items, continuation: continuation)
    }

    private static func chip(_ node: JSONNode) -> HomeFeedChip? {
        let renderer = node["chipCloudChipRenderer"]
        guard let title = renderer["text"]["simpleText"].string ?? renderer["text"].runsText else { return nil }
        return HomeFeedChip(
            title: title,
            params: renderer["navigationEndpoint"]["browseEndpoint"]["params"].string,
            isSelected: renderer["isSelected"].bool ?? false,
            continuation: renderer["navigationEndpoint"]["continuationCommand"]["token"].string
                ?? renderer["onTap"]["innertubeCommand"]["continuationCommand"]["token"].string
        )
    }

    private static func shelf(from content: JSONNode) -> HomeFeedSection? {
        let shelf = content["richShelfRenderer"]
        guard shelf.exists else { return nil }
        let title = shelf["title"]["simpleText"].string ?? shelf["title"].runsText
        guard !isShortsShelf(shelf, title: title) else { return nil }
        var videos: [Video] = []
        for entry in shelf["contents"].array {
            let item = entry["richItemRenderer"]["content"]
            if let video = contentVideo(item) {
                videos.append(video)

            }
        }
        guard !videos.isEmpty else { return nil }
        return HomeFeedSection(id: (title ?? "shelf") + "-" + (videos.first?.id ?? ""), title: title, videos: videos)
    }

    /// `videoRenderer` → `Video`. Text fields come as either `simpleText` or `runs`.
    static func video(from r: JSONNode) -> Video? {
        guard let id = r["videoId"].string, let title = r["title"].runsText ?? r["title"]["simpleText"].string else { return nil }
        let owner = r["ownerText"].exists ? r["ownerText"] : (r["longBylineText"].exists ? r["longBylineText"] : r["shortBylineText"])
        let channelName = owner.runsText ?? ""
        let channelID = owner["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
        let avatar = r["channelThumbnailSupportedRenderers"]["channelThumbnailWithLinkRenderer"]["thumbnail"]["thumbnails"]
        let overlayStyles = r["thumbnailOverlays"].array.compactMap { $0["thumbnailOverlayTimeStatusRenderer"]["style"].string }
        if overlayStyles.contains("SHORTS") { return nil }
        let isLive = r["badges"].array.contains { $0["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_LIVE_NOW" }
            || overlayStyles.contains("LIVE")
        return Video(
            id: id,
            title: title,
            channelID: channelID,
            channelName: channelName,
            channelThumbnailURL: largest(avatar),
            thumbnailURL: largest(r["thumbnail"]["thumbnails"]) ?? Mappers.canonicalThumbnailURL(for: id),
            duration: MusicResponseParser.parseDuration(r["lengthText"]["simpleText"].string),
            viewCount: Mappers.parseViewCount(r["viewCountText"]["simpleText"].string ?? r["shortViewCountText"]["simpleText"].string),
            publishedAt: nil,
            publishedRelative: r["publishedTimeText"]["simpleText"].string,
            descriptionSnippet: r["descriptionSnippet"].runsText,
            isLive: isLive,
            isShort: false
        )
    }

    private static func isShortsShelf(_ shelf: JSONNode, title: String?) -> Bool {
        if shelf["isShorts"].bool == true { return true }
        let normalized = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "shorts" || normalized == "#shorts"
    }

    /// Current WEB feeds use lockup view models; older responses still use videoRenderer.
    private static func contentVideo(_ content: JSONNode) -> Video? {
        if content["shortsLockupViewModel"].exists || content["reelItemRenderer"].exists { return nil }
        if let legacy = video(from: content["videoRenderer"]) { return legacy }
        let r = content["lockupViewModel"]
        if let type = r["contentType"].string, type.contains("SHORT") { return nil }
        guard r["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = r["contentId"].string else { return nil }
        let metadata = r["metadata"]["lockupMetadataViewModel"]
        guard let title = metadata["title"]["content"].string else { return nil }
        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        let parts = rows.flatMap { $0["metadataParts"].array }
        let avatar = metadata["image"]["decoratedAvatarViewModel"]
        let channelPart = parts.first {
            $0["text"]["commandRuns"][0]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string != nil
        }
        let channelID = avatar["rendererContext"]["commandContext"]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string
            ?? channelPart?["text"]["commandRuns"][0]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string ?? ""
        let stats = rows.last?["metadataParts"].array ?? []
        let thumbnail = r["contentImage"]["thumbnailViewModel"]
        let badges = thumbnail["overlays"].array.flatMap {
            $0["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array
                + $0["thumbnailBottomOverlayViewModel"]["badges"].array
        }.map { $0["thumbnailBadgeViewModel"] }
        let duration = badges.compactMap { MusicResponseParser.parseDuration($0["text"].string) }.first
        return Video(
            id: id, title: title, channelID: channelID,
            channelName: channelPart?["text"]["content"].string ?? parts.first?["text"]["content"].string ?? "",
            channelThumbnailURL: largest(avatar["avatar"]["avatarViewModel"]["image"]["sources"]),
            thumbnailURL: largest(thumbnail["image"]["sources"]) ?? Mappers.canonicalThumbnailURL(for: id),
            duration: duration,
            viewCount: Mappers.parseViewCount(stats.first?["text"]["content"].string),
            publishedAt: nil, publishedRelative: stats.count > 1 ? stats.last?["text"]["content"].string : nil,
            descriptionSnippet: nil,
            isLive: badges.contains { $0["style"].string == "THUMBNAIL_BADGE_STYLE_LIVE" },
            isShort: false
        )
    }

    private static func largest(_ thumbnails: JSONNode) -> URL? {
        thumbnails.array.compactMap { $0["url"].string }.last.flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
    }
}

/// Google's request-origin binding for cookie sessions, shared by every raw InnerTube client.
enum InnerTubeAuth {
    /// `SAPISIDHASH <unix-seconds>_<sha1("<seconds> <SAPISID> <origin>")>`.
    static func sapisidHash(cookies: String, origin: String, now: Date = .now) -> String? {
        MusicService.sapisidHash(cookies: cookies, origin: origin, now: now)
    }
}
