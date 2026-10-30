import Combine
import Foundation
import UniEatCore

private struct CachedFeed: Codable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
    var timeReference: ServerTimeReference?
}

/// Shared feed result: recommendations and filters consume this same source of truth.
@MainActor
final class FeedViewModel: FeatureViewModel {
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCachedFeed = false
    @Published private(set) var loadError: String?
    private let api: APIRequesting
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    private let events: EventService
    private var requestID = UUID()
    private var refreshTask: Task<Void, Never>?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         clock: ServerClock, events: EventService) {
        self.api = api; self.session = session; self.connectivity = connectivity
        self.clock = clock; self.events = events
        super.init(); observe(connectivity); observe(clock)
    }
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: clock.now) } }
    var isOffline: Bool { connectivity.isOffline }
    var isAdmin: Bool { session.isAdmin }
    func accountChanged() {
        refreshTask?.cancel(); requestID = UUID()
        menus = []; isLoading = false; loadError = nil; isShowingCachedFeed = false
        guard session.profile != nil else { return }
        filters = LocalValues.load(FeedFilters.self, key: "unieat.filters") ?? FeedFilters()
        loadCachedFeed()
        refreshTask = Task { await refresh() }
    }
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        LocalValues.save(newFilters, key: "unieat.filters")
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }
    func refresh() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = filters, id = UUID()
        requestID = id; isLoading = true; loadError = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let feed: FeedResponse = try await api.get("feed", query: requested.queryItems)
            try Task.checkCancellation()
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            clock.synchronize(feed.serverNow ?? feed.fetchedAt)
            menus = feed.menus; fetchedAt = feed.fetchedAt
            connectivity.serverUnreachable = false; isShowingCachedFeed = false
            LocalValues.save(CachedFeed(userId: userID, filters: requested, response: feed,
                                        timeReference: clock.snapshot()), key: "unieat.remote.feed-cache.v1")
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            connectivity.serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadError = error.localizedDescription
            loadCachedFeed()
        }
    }
    private func loadCachedFeed() {
        guard let cached = LocalValues.load(CachedFeed.self, key: "unieat.remote.feed-cache.v1"),
              cached.userId == session.profile?.id, cached.filters == filters else {
            menus = []; isShowingCachedFeed = false; return
        }
        if let reference = cached.timeReference { clock.restore(reference) }
        menus = cached.response.menus; fetchedAt = cached.response.fetchedAt; isShowingCachedFeed = true
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
}
