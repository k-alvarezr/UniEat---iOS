import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class FeedOptimizationTests: XCTestCase {
    func testCompatibleLiveFeedDoesNotBecomeTheOlderDiskCopyWhileRefreshing() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        content.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let shown = makeMenu(title: "En pantalla"), old = makeMenu(title: "Copia anterior")
        try await seedCatalog(content, h: h, menus: [shown])
        let api = FeedOptimizationAPI { _ in FeedResponse(fetchedAt: .now, menus: [shown]) }
        let feed = makeFeed(h, api: api, content: content)
        await feed.refresh(force: true)
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: feed.fetchedAt, menus: [old])))
        let started = expectation(description: "Petición en curso")
        var pending: CheckedContinuation<FeedResponse, Error>?
        api.respond = { _ in try await withCheckedThrowingContinuation { pending = $0; started.fulfill() } }
        let refresh = Task { await feed.refresh(force: true) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(feed.visibleMenus.map(\.id), [shown.id])
        XCTAssertFalse(feed.isShowingCachedFeed)
        XCTAssertTrue(feed.isLoading)
        pending?.resume(returning: FeedResponse(fetchedAt: .now, menus: [shown]))
        await refresh.value
        XCTAssertNil(feed.cacheWarning)
    }

    func testFreshDurableCatalogSkipsWarmUpAndDoesNotPrefetchItsPhotos() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        content.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let shown = makeMenu(title: "Compatible"), other = makeMenu(title: "Otro menú")
        try await seedCatalog(content, h: h, menus: [shown, other])
        let noWarmUp = expectation(description: "No se repite catálogo reciente")
        noWarmUp.isInverted = true
        let api = FeedOptimizationAPI { query in
            if query.contains(where: { $0.name == "refresh" }) { noWarmUp.fulfill() }
            return FeedResponse(fetchedAt: .now, menus: [shown])
        }
        let feed = makeFeed(h, api: api, content: content)
        var prefetched: [[UUID]] = []
        feed.onMenusLoaded = { prefetched.append($0.map(\.id)) }
        await feed.refresh(force: true)
        await fulfillment(of: [noWarmUp], timeout: 0.2)
        XCTAssertEqual(api.queries.count, 1)
        XCTAssertEqual(prefetched, [[shown.id]])
        XCTAssertEqual(Set(feed.locationMenus.map(\.id)), Set([shown.id, other.id]))
    }

    func testUnfilteredResponseIsReusedAsCatalogWithoutAnotherRequest() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        content.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let menu = h.menu
        let api = FeedOptimizationAPI { _ in FeedResponse(fetchedAt: .now, menus: [menu]) }
        let feed = makeFeed(h, api: api, content: content)
        let loaded = expectation(description: "Feed sin filtros cargado")
        feed.onMenusLoaded = { _ in loaded.fulfill() }
        let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
        feed.updateFilters(all)
        await fulfillment(of: [loaded], timeout: 3)
        let limit = Date.now.addingTimeInterval(3)
        while feed.isLoading && Date.now < limit { await Task.yield() }
        XCTAssertFalse(feed.isLoading)
        let catalog = try await content.feed(userID: h.auth.profile.id, filters: all, catalog: true)
        XCTAssertEqual(catalog?.response.menus.map(\.id), [menu.id])
        XCTAssertEqual(api.queries.count, 1)
        XCTAssertTrue(api.queries[0].isEmpty)
    }

    func testExposureKeyChangesForEligibilityNotEveryRefresh() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        content.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let menu = h.menu
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: .now, menus: [menu])))
        try await seedCatalog(content, h: h, menus: [menu])
        let api = FeedOptimizationAPI { _ in FeedResponse(fetchedAt: .now, menus: [menu]) }
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        var metadata: ExperimentEventMetadata?
        events.metadataProvider = { _ in metadata }
        let feed = FeedViewModel(api: api, session: h.session, connectivity: h.connectivity,
            clock: h.clock, events: events, content: content)
        h.connectivity.update(isConnected: false)
        await feed.refresh()
        let copied = feed.exposureKey(for: menu)
        metadata = ExperimentEventMetadata(assignmentId: UUID(), experimentKey: "bq08-wait-v1", variant: "control",
            indicatorAvailable: true, indicatorShown: false, source: "live")
        h.connectivity.update(isConnected: true)
        await feed.refresh(force: true)
        let eligible = feed.exposureKey(for: menu)
        XCTAssertNotEqual(copied, eligible)
        await feed.refresh(force: true)
        XCTAssertEqual(feed.exposureKey(for: menu), eligible)
        events.restartSession()
        XCTAssertNotEqual(feed.exposureKey(for: menu), eligible)
    }

    func testUpgradeCanStillOpenTheOldUnfilteredSnapshotWithoutACatalog() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        content.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
        let menu = h.menu
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: all,
            response: FeedResponse(fetchedAt: .now, menus: [menu])))
        h.connectivity.update(isConnected: false)
        let api = FeedOptimizationAPI { _ in XCTFail("La migración offline no pide red"); return FeedResponse(fetchedAt: .now, menus: []) }
        let feed = makeFeed(h, api: api, content: content)
        feed.updateFilters(all)
        let limit = Date.now.addingTimeInterval(3)
        while (!feed.hasSnapshot || feed.isLoading) && Date.now < limit { await Task.yield() }
        XCTAssertEqual(feed.visibleMenus.map(\.id), [menu.id])
        XCTAssertTrue(feed.isShowingCachedFeed)
        XCTAssertTrue(api.queries.isEmpty)
    }

    private func makeFeed(_ h: Harness, api: FeedOptimizationAPI, content: LocalContentService) -> FeedViewModel {
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        return FeedViewModel(api: api, session: h.session, connectivity: h.connectivity, clock: h.clock,
            events: events, content: content)
    }
    private func seedCatalog(_ content: LocalContentService, h: Harness, menus: [DailyMenu]) async throws {
        let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: all,
            response: FeedResponse(fetchedAt: .now, menus: menus)), isCatalog: true)
    }
}

@MainActor
private final class FeedOptimizationAPI: APIRequesting {
    var respond: ([URLQueryItem]) async throws -> FeedResponse
    private(set) var queries: [[URLQueryItem]] = []
    init(_ respond: @escaping ([URLQueryItem]) async throws -> FeedResponse) { self.respond = respond }
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        guard path == "feed" else { throw APIFailure.unexpected }
        queries.append(query)
        let response = try await respond(query)
        return try UniEatDates.decoder().decode(Response.self, from: UniEatDates.encoder().encode(response))
    }
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
        query: [URLQueryItem], body: Body?) async throws -> Response { throw APIFailure.unexpected }
}
