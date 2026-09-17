import Foundation
import Observation

/// One of the fixed surfaces (Home / Explore / Library). Home pages through YouTube's
/// continuation tokens; Library is only requested when signed in.
@available(iOS 17.0, *)
@Observable
@MainActor
final class MusicSurfaceViewModel {
    let surface: MusicSurface
    private(set) var shelves: [MusicShelf] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    var errorState: ErrorState?
    private var continuation: String?
    private let service: any MusicServicing

    init(surface: MusicSurface, service: any MusicServicing = MusicService.shared) {
        self.surface = surface
        self.service = service
    }

    var canLoadMore: Bool { continuation != nil && !isLoadingMore }

    func load(force: Bool = false) async {
        guard force || !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.page(browseID: surface.browseID)
            shelves = page.shelves
            continuation = page.continuation
            hasLoaded = true
        } catch {
            errorState = ErrorState(from: error)
            if case YouTubeServiceError.cookieExpired = error {
                await SessionManager.shared.handleExpiredSession()
            }
        }
    }

    func loadMore() async {
        guard let token = continuation, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await service.continuation(token, pageID: surface.browseID, offset: shelves.count)
            let known = Set(shelves.map(\.id))
            shelves.append(contentsOf: more.shelves.filter { !known.contains($0.id) })
            continuation = more.shelves.isEmpty ? nil : more.continuation
        } catch {
            continuation = nil
        }
    }

    /// Signing in or out changes what Home shows; drop the cached page.
    func invalidate() {
        hasLoaded = false
        shelves = []
        continuation = nil
    }
}

/// Album, artist or playlist page.
@available(iOS 17.0, *)
@Observable
@MainActor
final class MusicBrowseViewModel {
    let browseID: String
    private(set) var page: MusicPage?
    private(set) var isLoading = false
    var errorState: ErrorState?
    private let service: any MusicServicing

    init(browseID: String, service: any MusicServicing = MusicService.shared) {
        self.browseID = browseID
        self.service = service
    }

    func load() async {
        guard page == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            page = try await service.page(browseID: browseID)
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}

@available(iOS 17.0, *)
@Observable
@MainActor
final class MusicSearchViewModel {
    var query = ""
    var filter: MusicSearchFilter = .all {
        didSet { if oldValue != filter, !query.isEmpty { Task { await submit() } } }
    }
    private(set) var shelves: [MusicShelf] = []
    private(set) var isLoading = false
    private(set) var lastSubmittedQuery: String?
    var errorState: ErrorState?
    private let service: any MusicServicing
    private var task: Task<Void, Never>?

    init(service: any MusicServicing = MusicService.shared) {
        self.service = service
    }

    var hasResults: Bool { !shelves.isEmpty }

    func submit() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        task?.cancel()
        let filter = filter
        let run = Task { [service] in
            try await service.search(query: trimmed, filter: filter)
        }
        task = Task { _ = await run.result }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await run.value
            guard !Task.isCancelled else { return }
            shelves = result.shelves
            lastSubmittedQuery = trimmed
        } catch is CancellationError {
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func clear() {
        task?.cancel()
        shelves = []
        lastSubmittedQuery = nil
    }
}
