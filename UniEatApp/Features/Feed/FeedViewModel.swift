import Combine
import Foundation
import UniEatCore

/// Shared feed state: short-lived memory cache, durable snapshots and an offline catalog.
@MainActor
final class FeedViewModel: FeatureViewModel {
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var locationMenus: [DailyMenu] = []
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCachedFeed = false
    @Published private(set) var hasSnapshot = false
    @Published private(set) var loadError: String?
    @Published private(set) var cacheWarning: String?
    @Published private(set) var contentRevision = UUID()
    private let api: APIRequesting
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    private let events: EventService
    private let content: LocalContentService?
    private let memory: FeedMemoryCache
    private var requestID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogAt: Date?
    var onServiceAvailable: (() -> Void)?
    var onMenusLoaded: (([DailyMenu]) -> Void)?
    var prepareContext: (() async -> Void)?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         clock: ServerClock, events: EventService, content: LocalContentService? = nil,
         memory: FeedMemoryCache? = nil) {
        self.api = api; self.session = session; self.connectivity = connectivity
        self.clock = clock; self.events = events; self.content = content
        self.memory = memory ?? FeedMemoryCache()
        super.init(); observe(connectivity); observe(clock)
    }
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: clock.now) } }
    var isOffline: Bool { connectivity.isOffline }
    var isAdmin: Bool { session.isAdmin }
    func accountChanged() {
        refreshTask?.cancel(); catalogTask?.cancel(); catalogTask = nil; catalogAt = nil
        requestID = UUID(); memory.clear()
        menus = []; locationMenus = []; isLoading = false; loadError = nil; cacheWarning = nil; isShowingCachedFeed = false; hasSnapshot = false
        guard session.profile != nil else { return }
        filters = LocalValues.load(FeedFilters.self, key: "unieat.filters") ?? FeedFilters()
        refreshTask = Task { await refresh() }
    }
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        LocalValues.save(newFilters, key: "unieat.filters")
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }
    func refresh(force: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = filters, id = UUID()
        requestID = id; isLoading = true; loadError = nil; cacheWarning = nil
        defer { if requestID == id { isLoading = false } }
        if !force, !connectivity.isOffline, let cached = memory.value(userID: userID, filters: requested) {
            apply(cached, stored: false); return
        }
        if !connectivity.isConnected {
            await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
            if session.matches(userID, generation: generation), requestID == id { loadError = APIFailure.offline.message }
            return
        }
        // Preserve Juan's cached-first launch: show the copy while its refresh is pending.
        await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
        guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
        do {
            await prepareContext?()
            guard session.matches(userID, generation: generation), requestID == id else { return }
            let feed: FeedResponse = try await api.get("feed", query: requested.queryItems)
            try Task.checkCancellation()
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            clock.synchronize(feed.serverNow ?? feed.fetchedAt)
            let snapshot = CachedFeedSnapshot(userId: userID, filters: requested, response: feed, timeReference: clock.snapshot())
            memory.insert(snapshot)
            if let content {
                do { try await content.saveFeed(snapshot) }
                catch { if session.matches(userID, generation: generation), requestID == id { cacheWarning = "El feed se cargó, pero no se pudo guardar su copia." } }
            }
            guard session.matches(userID, generation: generation), requestID == id else { return }
            apply(snapshot, stored: false); connectivity.serverUnreachable = false
            onServiceAvailable?(); onMenusLoaded?(feed.menus)
            refreshCatalog(userID: userID, generation: generation)
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            connectivity.serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadError = error.localizedDescription
            await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
        }
    }
    private func apply(_ snapshot: CachedFeedSnapshot, stored: Bool) {
        if let reference = snapshot.timeReference { clock.restore(reference) }
        menus = snapshot.response.menus; fetchedAt = snapshot.response.fetchedAt; isShowingCachedFeed = stored; hasSnapshot = true
        contentRevision = UUID() // remount cards after a pilot/context change so exposure is recorded.
        if locationMenus.isEmpty { locationMenus = menus }
    }
    private func loadCachedFeed(userID: UUID, generation: UUID, request: UUID, requested: FeedFilters) async {
        var snapshot: CachedFeedSnapshot?
        var catalog: CachedFeedSnapshot?
        if let content {
            do {
                snapshot = try await content.feed(userID: userID, filters: requested)
                catalog = try await content.feed(userID: userID, filters: requested, catalog: true)
            } catch { if session.matches(userID, generation: generation), requestID == request { cacheWarning = "No se pudo leer la copia local del feed." } }
        }
        if snapshot == nil, let old = LocalValues.load(CachedFeedSnapshot.self, key: "unieat.remote.feed-cache.v1"),
           old.userId == userID, old.filters == requested { snapshot = old }
        guard session.matches(userID, generation: generation), requestID == request, requested == filters else { return }
        if let catalog {
            if let reference = catalog.timeReference { clock.restore(reference) }
            locationMenus = catalog.response.menus
            if snapshot == nil {
                snapshot = CachedFeedSnapshot(userId: userID, filters: requested,
                    response: FeedResponse(fetchedAt: catalog.response.fetchedAt,
                        menus: OfflineMenuFiltering.filter(catalog.response.menus, filters: requested, at: clock.now)),
                    timeReference: catalog.timeReference)
            }
        }
        if let snapshot { apply(snapshot, stored: true) }
        else { menus = []; isShowingCachedFeed = false; hasSnapshot = false }
    }
    private func refreshCatalog(userID: UUID, generation: UUID) {
        guard let content, catalogTask == nil,
              catalogAt == nil || clock.now.timeIntervalSince(catalogAt!) > 30 else { return }
        catalogTask = Task {
            defer { if session.matches(userID, generation: generation) { catalogTask = nil } }
            do {
                let response: FeedResponse = try await api.get("feed", query: [.init(name: "refresh", value: "auto")])
                guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
                let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
                try await content.saveFeed(CachedFeedSnapshot(userId: userID, filters: all, response: response,
                    timeReference: clock.snapshot()), isCatalog: true)
                guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
                locationMenus = response.menus; catalogAt = clock.now; onMenusLoaded?(response.menus)
            } catch { /* An optional warm-up cannot hide a valid live feed. */ }
        }
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
}
