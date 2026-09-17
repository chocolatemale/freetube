import Foundation

/// Minimal read-only cursor over `JSONSerialization` output. InnerTube responses are deep,
/// irregular trees; a cursor that returns an empty node instead of trapping keeps the parser
/// short and makes every lookup safe by construction.
struct JSONNode: @unchecked Sendable {
    /// Plain Foundation objects from `JSONSerialization`; never mutated after creation.
    let value: Any?

    init(_ value: Any?) { self.value = value }

    subscript(_ key: String) -> JSONNode {
        JSONNode((value as? [String: Any])?[key])
    }

    subscript(_ index: Int) -> JSONNode {
        guard let array = value as? [Any], array.indices.contains(index) else { return JSONNode(nil) }
        return JSONNode(array[index])
    }

    var array: [JSONNode] { (value as? [Any])?.map(JSONNode.init) ?? [] }
    var string: String? { value as? String }
    var int: Int? { (value as? NSNumber)?.intValue }
    var exists: Bool { value != nil }
    /// First key of a single-entry renderer wrapper such as `{"musicShelfRenderer": {...}}`.
    var rendererName: String? { (value as? [String: Any])?.keys.first }
    var firstValue: JSONNode { JSONNode((value as? [String: Any])?.values.first) }

    /// Joins `runs[].text`.
    var runsText: String? {
        let parts = self["runs"].array.compactMap { $0["text"].string }
        return parts.isEmpty ? nil : parts.joined()
    }
}

/// Turns raw `WEB_REMIX` InnerTube JSON into `MusicShelf` / `MusicItem` / `MusicPage`.
///
/// The parser is deliberately structural rather than page-specific: it walks every
/// `sectionListRenderer` it can find (single-column tabs, two-column headers + secondary
/// contents, continuation payloads) and converts each shelf renderer it recognises. Pages whose
/// wrapper changes still render as long as the leaf renderers stay the same — which is what has
/// been stable across years of music.youtube.com redesigns.
enum MusicResponseParser {
    // MARK: - Pages

    static func page(browseID: String, from root: JSONNode) -> MusicPage {
        var title = ""
        var subtitle: String?
        var description: String?
        var thumbnail: URL?
        var tracks: [MusicItem] = []
        var shelves: [MusicShelf] = []
        var continuation: String?
        var albumFallbackArt: URL?

        // Headers: immersive (artist), responsive (album/playlist, inside the tab section list),
        // or the legacy detail header.
        if let header = root["header"].firstValue.exists ? root["header"].firstValue : nil {
            title = header["title"].runsText ?? ""
            subtitle = header["subtitle"].runsText
            description = header["description"].runsText
                ?? header["description"]["musicDescriptionShelfRenderer"]["description"].runsText
            thumbnail = bestThumbnail(header["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"])
                ?? bestThumbnail(header["thumbnail"]["croppedSquareThumbnailRenderer"]["thumbnail"]["thumbnails"])
        }

        for sectionList in sectionLists(in: root) {
            if let token = sectionList["continuations"][0]["nextContinuationData"]["continuation"].string {
                continuation = token
            }
            for section in sectionList["contents"].array {
                guard let name = section.rendererName else { continue }
                let body = section[name]
                switch name {
                case "musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicVisualHeaderRenderer":
                    title = body["title"].runsText ?? title
                    subtitle = [body["subtitle"].runsText, body["secondSubtitle"].runsText]
                        .compactMap { $0 }
                        .joined(separator: " • ")
                        .nilIfEmpty ?? subtitle
                    description = description
                        ?? body["description"]["musicDescriptionShelfRenderer"]["description"].runsText
                        ?? body["description"].runsText
                    thumbnail = thumbnail
                        ?? bestThumbnail(body["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"])
                    albumFallbackArt = thumbnail
                case "musicShelfRenderer", "musicPlaylistShelfRenderer":
                    let items = body["contents"].array.compactMap { item($0, fallbackArt: albumFallbackArt) }
                    let shelfTitle = body["title"].runsText
                    // Album/playlist bodies are untitled track lists; artist "Top songs" is titled.
                    if shelfTitle == nil || name == "musicPlaylistShelfRenderer" {
                        tracks.append(contentsOf: items)
                        if let token = body["continuations"][0]["nextContinuationData"]["continuation"].string {
                            continuation = token
                        }
                    } else if !items.isEmpty {
                        shelves.append(MusicShelf(
                            id: "\(browseID)-\(shelves.count)-\(shelfTitle ?? "")",
                            title: shelfTitle ?? "",
                            subtitle: nil,
                            layout: .list,
                            items: items,
                            moreBrowseID: body["bottomEndpoint"]["browseEndpoint"]["browseId"].string
                                ?? body["title"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
                        ))
                    }
                case "musicDescriptionShelfRenderer":
                    description = description ?? body["description"].runsText
                default:
                    if let shelf = shelf(name: name, body: body, index: shelves.count, pageID: browseID) {
                        shelves.append(shelf)
                    }
                }
            }
        }

        return MusicPage(
            browseID: browseID,
            title: title,
            subtitle: subtitle?.nilIfEmpty,
            description: description?.nilIfEmpty,
            thumbnailURL: thumbnail,
            tracks: tracks,
            shelves: shelves,
            continuation: continuation
        )
    }

    /// Shelves appended by a `continuation` request (home feed paging).
    static func continuationShelves(pageID: String, offset: Int, from root: JSONNode) -> (shelves: [MusicShelf], continuation: String?) {
        var shelves: [MusicShelf] = []
        var next: String?
        for sectionList in sectionLists(in: root) {
            next = sectionList["continuations"][0]["nextContinuationData"]["continuation"].string ?? next
            for section in sectionList["contents"].array {
                guard let name = section.rendererName,
                      let shelf = shelf(name: name, body: section[name], index: offset + shelves.count, pageID: pageID) else { continue }
                shelves.append(shelf)
            }
        }
        return (shelves, next)
    }

    /// Search results: the "top result" card becomes its own shelf, filtered searches come back
    /// as one `musicShelfRenderer`, and the unfiltered layout is a run of single-item sections
    /// that we fold into one list.
    static func searchShelves(from root: JSONNode) -> (shelves: [MusicShelf], continuation: String?) {
        var shelves: [MusicShelf] = []
        var loose: [MusicItem] = []
        var continuation: String?
        for sectionList in sectionLists(in: root) {
            for section in sectionList["contents"].array {
                guard let name = section.rendererName else { continue }
                let body = section[name]
                switch name {
                case "musicCardShelfRenderer":
                    var items: [MusicItem] = []
                    let top = cardItem(body)
                    if let top { items.append(top) }
                    items.append(contentsOf: body["contents"].array.compactMap {
                        item($0, fallbackArt: nil, fallbackSubtitle: top?.kind == .artist ? top?.title : nil)
                    })
                    if !items.isEmpty {
                        shelves.append(MusicShelf(id: "search-top", title: String(localized: "Top result"), subtitle: nil, layout: .list, items: items, moreBrowseID: nil))
                    }
                case "musicShelfRenderer":
                    let items = body["contents"].array.compactMap { item($0, fallbackArt: nil) }
                    continuation = body["continuations"][0]["nextContinuationData"]["continuation"].string ?? continuation
                    if !items.isEmpty {
                        shelves.append(MusicShelf(id: "search-\(shelves.count)", title: body["title"].runsText ?? "", subtitle: nil, layout: .list, items: items, moreBrowseID: nil))
                    }
                case "itemSectionRenderer":
                    loose.append(contentsOf: body["contents"].array.compactMap { item($0, fallbackArt: nil) })
                default:
                    continue
                }
            }
        }
        if !loose.isEmpty {
            shelves.append(MusicShelf(id: "search-results", title: String(localized: "Results"), subtitle: nil, layout: .list, items: loose, moreBrowseID: nil))
        }
        return (shelves, continuation)
    }

    /// Radio / "Up next" queue from `/next`.
    static func queue(from root: JSONNode) -> [MusicItem] {
        let panel = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]["tabs"][0]["tabRenderer"]["content"]["musicQueueRenderer"]["content"]["playlistPanelRenderer"]
        return panel["contents"].array.compactMap { entry in
            let renderer = entry["playlistPanelVideoRenderer"].exists
                ? entry["playlistPanelVideoRenderer"]
                : entry["playlistPanelVideoWrapperRenderer"]["primaryRenderer"]["playlistPanelVideoRenderer"]
            guard let videoID = renderer["videoId"].string, let title = renderer["title"].runsText else { return nil }
            return MusicItem(
                id: videoID,
                kind: .song,
                title: title,
                subtitle: renderer["shortBylineText"].runsText ?? "",
                thumbnailURL: bestThumbnail(renderer["thumbnail"]["thumbnails"]),
                duration: parseDuration(renderer["lengthText"].runsText),
                artistBrowseID: renderer["shortBylineText"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                playlistID: renderer["navigationEndpoint"]["watchEndpoint"]["playlistId"].string
            )
        }
    }

    // MARK: - Shelves

    private static func shelf(name: String, body: JSONNode, index: Int, pageID: String) -> MusicShelf? {
        switch name {
        case "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer":
            let header = body["header"]["musicCarouselShelfBasicHeaderRenderer"]
            let items = body["contents"].array.compactMap { item($0, fallbackArt: nil) }
            guard !items.isEmpty else { return nil }
            let usesRows = body["contents"][0].rendererName == "musicResponsiveListItemRenderer"
            return MusicShelf(
                id: "\(pageID)-\(index)",
                title: header["title"].runsText ?? "",
                subtitle: header["strapline"].runsText,
                layout: usesRows ? .list : .carousel,
                items: items,
                moreBrowseID: header["moreContentButton"]["buttonRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
                    ?? header["title"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            )
        case "gridRenderer":
            let items = body["items"].array.compactMap { item($0, fallbackArt: nil) }
            guard !items.isEmpty else { return nil }
            return MusicShelf(
                id: "\(pageID)-\(index)",
                title: body["header"]["gridHeaderRenderer"]["title"].runsText ?? "",
                subtitle: nil,
                layout: .grid,
                items: items,
                moreBrowseID: nil
            )
        case "itemSectionRenderer":
            // Library landing wraps grids in item sections.
            for inner in body["contents"].array {
                if let innerName = inner.rendererName,
                   let shelf = shelf(name: innerName, body: inner[innerName], index: index, pageID: pageID) {
                    return shelf
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Items

    static func item(_ node: JSONNode, fallbackArt: URL?, fallbackSubtitle: String? = nil) -> MusicItem? {
        if node["musicTwoRowItemRenderer"].exists {
            return twoRowItem(node["musicTwoRowItemRenderer"])
        }
        if node["musicResponsiveListItemRenderer"].exists {
            return listItem(node["musicResponsiveListItemRenderer"], fallbackArt: fallbackArt, fallbackSubtitle: fallbackSubtitle)
        }
        return nil
    }

    private static func twoRowItem(_ r: JSONNode) -> MusicItem? {
        guard let title = r["title"].runsText else { return nil }
        let subtitle = r["subtitle"].runsText ?? ""
        let art = bestThumbnail(r["thumbnailRenderer"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"])
        let nav = r["navigationEndpoint"]
        if let videoID = nav["watchEndpoint"]["videoId"].string {
            return MusicItem(
                id: videoID,
                kind: nav["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string == "MUSIC_VIDEO_TYPE_ATV" ? .song : .video,
                title: title,
                subtitle: subtitle,
                thumbnailURL: art,
                duration: nil,
                artistBrowseID: r["subtitle"]["runs"].array.compactMap { $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string }.first,
                playlistID: nav["watchEndpoint"]["playlistId"].string
            )
        }
        if let browseID = nav["browseEndpoint"]["browseId"].string {
            let kind = kind(forPageType: nav["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string, browseID: browseID)
            return MusicItem(id: browseID, kind: kind, title: title, subtitle: subtitle, thumbnailURL: art, duration: nil, artistBrowseID: nil, playlistID: nil)
        }
        // Mixes expose only a play endpoint; surface them as playlists.
        if let playlistID = r["thumbnailOverlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchPlaylistEndpoint"]["playlistId"].string {
            return MusicItem(id: "VL" + playlistID, kind: .playlist, title: title, subtitle: subtitle, thumbnailURL: art, duration: nil, artistBrowseID: nil, playlistID: playlistID)
        }
        return nil
    }

    private static func listItem(_ r: JSONNode, fallbackArt: URL?, fallbackSubtitle: String?) -> MusicItem? {
        let columns = r["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
        guard let title = columns.first?.runsText else { return nil }
        let secondary = columns.dropFirst().first
        var subtitle = secondary?.runsText ?? ""
        let art = bestThumbnail(r["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"]) ?? fallbackArt
        let artistBrowseID = secondary?["runs"].array
            .compactMap { $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string }
            .first { $0.hasPrefix("UC") }
        let fixed = r["fixedColumns"][0]["musicResponsiveListItemFixedColumnRenderer"]["text"].runsText
        var duration = parseDuration(fixed)

        let titleNav = columns.first?["runs"][0]["navigationEndpoint"]
        let videoID = r["playlistItemData"]["videoId"].string
            ?? titleNav?["watchEndpoint"]["videoId"].string
            ?? r["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
        if let videoID {
            let type = titleNav?["watchEndpoint"]["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string
            // Search rows spell out "Song • Artist • Album"; keep the artist/album part. Inside a
            // top-result card the artist is implied and the column holds only "Song • 5:38".
            if subtitle.hasPrefix("Song • ") || subtitle.hasPrefix("Video • ") {
                subtitle = String(subtitle.drop(while: { $0 != "•" }).dropFirst(2))
            }
            if let trailing = subtitle.split(separator: "•").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
               let parsed = parseDuration(trailing) {
                duration = duration ?? parsed
                subtitle = subtitle.replacingOccurrences(of: trailing, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " •"))
            }
            if subtitle.isEmpty, let fallbackSubtitle { subtitle = fallbackSubtitle }
            return MusicItem(
                id: videoID,
                kind: type == "MUSIC_VIDEO_TYPE_ATV" ? .song : (type == nil ? .song : .video),
                title: title,
                subtitle: subtitle,
                thumbnailURL: art,
                duration: duration,
                artistBrowseID: artistBrowseID,
                playlistID: titleNav?["watchEndpoint"]["playlistId"].string
            )
        }
        if let browseID = r["navigationEndpoint"]["browseEndpoint"]["browseId"].string {
            let pageType = r["navigationEndpoint"]["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
            return MusicItem(id: browseID, kind: kind(forPageType: pageType, browseID: browseID), title: title, subtitle: subtitle, thumbnailURL: art, duration: nil, artistBrowseID: artistBrowseID, playlistID: nil)
        }
        return nil
    }

    private static func cardItem(_ card: JSONNode) -> MusicItem? {
        guard let title = card["title"].runsText else { return nil }
        let subtitle = card["subtitle"].runsText ?? ""
        let art = bestThumbnail(card["thumbnail"]["musicThumbnailRenderer"]["thumbnail"]["thumbnails"])
        let nav = card["title"]["runs"][0]["navigationEndpoint"]
        if let videoID = nav["watchEndpoint"]["videoId"].string {
            return MusicItem(id: videoID, kind: .song, title: title, subtitle: subtitle, thumbnailURL: art, duration: nil, artistBrowseID: nil, playlistID: nil)
        }
        if let browseID = nav["browseEndpoint"]["browseId"].string {
            let pageType = nav["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
            return MusicItem(id: browseID, kind: kind(forPageType: pageType, browseID: browseID), title: title, subtitle: subtitle, thumbnailURL: art, duration: nil, artistBrowseID: nil, playlistID: nil)
        }
        return nil
    }

    // MARK: - Helpers

    private static func kind(forPageType pageType: String?, browseID: String) -> MusicItem.Kind {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": return .artist
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        default:
            if browseID.hasPrefix("UC") { return .artist }
            if browseID.hasPrefix("MPRE") { return .album }
            return .playlist
        }
    }

    /// Every `sectionListRenderer` reachable from the usual wrappers, in display order.
    private static func sectionLists(in root: JSONNode) -> [JSONNode] {
        var lists: [JSONNode] = []
        let contents = root["contents"]
        for tab in contents["singleColumnBrowseResultsRenderer"]["tabs"].array
            + contents["twoColumnBrowseResultsRenderer"]["tabs"].array
            + contents["tabbedSearchResultsRenderer"]["tabs"].array {
            let list = tab["tabRenderer"]["content"]["sectionListRenderer"]
            if list.exists { lists.append(list) }
        }
        let secondary = contents["twoColumnBrowseResultsRenderer"]["secondaryContents"]["sectionListRenderer"]
        if secondary.exists { lists.append(secondary) }
        let continued = root["continuationContents"]["sectionListContinuation"]
        if continued.exists { lists.append(continued) }
        // Shelf-level continuations come back as a bare shelf; wrap so the caller sees one list.
        let shelfContinuation = root["continuationContents"]["musicShelfContinuation"]
        if shelfContinuation.exists {
            lists.append(JSONNode(["contents": [["musicShelfRenderer": shelfContinuation.rawDictionary]], "continuations": shelfContinuation["continuations"].rawArray]))
        }
        let playlistContinuation = root["continuationContents"]["musicPlaylistShelfContinuation"]
        if playlistContinuation.exists {
            lists.append(JSONNode(["contents": [["musicPlaylistShelfRenderer": playlistContinuation.rawDictionary]], "continuations": playlistContinuation["continuations"].rawArray]))
        }
        return lists
    }

    /// Largest thumbnail, with YouTube's `=wNNN-hNNN` size suffix bumped to a crisp square.
    static func bestThumbnail(_ thumbnails: JSONNode) -> URL? {
        let candidates = thumbnails.array.compactMap { $0["url"].string }
        guard var best = candidates.last else { return nil }
        if let range = best.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            best.replaceSubrange(range, with: "=w544-h544")
        }
        return URL(string: best)
    }

    static func parseDuration(_ text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + TimeInterval($1) }
    }
}

private extension JSONNode {
    var rawDictionary: [String: Any] { value as? [String: Any] ?? [:] }
    var rawArray: [Any] { value as? [Any] ?? [] }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
