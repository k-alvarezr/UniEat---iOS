import XCTest
import SwiftData
import UniEatCore
@testable import UniEat

@MainActor
final class Sprint3Tests: XCTestCase {
    func testOpeningTheExpandedSchemaPreservesTheExistingDiskReportStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "upgrade.store"), owner = UUID(), reportID = UUID()
        try writeOriginalReportStore(url: url, owner: owner, reportID: reportID)
        let db = try LocalDatabase(storeURL: url)
        let reports = try db.pendingReports(userId: owner)
        XCTAssertEqual(reports.map(\.id), [reportID])
        XCTAssertEqual(reports.first?.snapshot?.version, 7)
        let content = LocalContentService(container: db.container)
        _ = try await content.toggle(makeMenu(title: "New saved menu"), userID: owner, savedAt: .now)
        XCTAssertEqual(try db.pendingReports(userId: owner).map(\.id), [reportID])
    }

    private func writeOriginalReportStore(url: URL, owner: UUID, reportID: UUID) throws {
        let schema = Schema([MenuSnapshot.self, PendingReport.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let snapshot = MenuSnapshot(userId: owner, menu: makeMenu(title: "Existing report", version: 7))
        let report = PendingReport(kind: "price", note: "Keep this work", waitMinutes: nil)
        report.id = reportID
        context.insert(snapshot); context.insert(report); report.snapshot = snapshot
        try context.save()
    }

    func testSavedMenuMigrationIsIdempotentRelationalAndScopedToUser() async throws {
        let db = try LocalDatabase(inMemory: true)
        let content = LocalContentService(container: db.container)
        let owner = UUID(), other = UUID()
        let menu = makeMenu(title: "Persisted", version: 3)
        let entry = SavedMenuEntry(menu: menu, savedAt: Date(timeIntervalSince1970: 1000))
        let data = try UniEatDates.encoder().encode([entry, entry])
        try await content.migrateSavedMenus(data, userID: owner)
        try await content.migrateSavedMenus(data, userID: owner)
        let rows = try await content.savedMenus(userID: owner)
        let others = try await content.savedMenus(userID: other)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].menu.version, 3)
        XCTAssertEqual(rows[0].menu.items.map(\.id), menu.items.map(\.id))
        XCTAssertTrue(others.isEmpty)
        let context = ModelContext(db.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedDish>()), 1)
        _ = try await content.toggle(menu, userID: owner, savedAt: .now)
        XCTAssertEqual(try ModelContext(db.container).fetchCount(FetchDescriptor<SavedDish>()), 0, "cascade deletes only the removed menu's dishes")
    }

    func testSavingContentDoesNotRemoveJuansPendingReportModels() async throws {
        let db = try LocalDatabase(inMemory: true), user = UUID(), menu = makeMenu(title: "Shared")
        try db.enqueueReport(userId: user, menu: menu, kind: "price", note: "", waitMinutes: nil)
        let content = LocalContentService(container: db.container)
        _ = try await content.toggle(menu, userID: user, savedAt: .now)
        let reports = try db.pendingReports(userId: user)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.snapshot?.menuId, menu.id)
    }

    func testMemoryCacheTTLAndUserFilterBoundaries() {
        var now = Date(timeIntervalSince1970: 1000)
        let cache = FeedMemoryCache(now: { now }), user = UUID(), filters = FeedFilters()
        let snapshot = CachedFeedSnapshot(userId: user, filters: filters,
            response: FeedResponse(fetchedAt: now, menus: [makeMenu(title: "Cached")]))
        cache.insert(snapshot)
        XCTAssertNotNil(cache.value(userID: user, filters: filters))
        XCTAssertNil(cache.value(userID: UUID(), filters: filters))
        XCTAssertNil(cache.value(userID: user, filters: FeedFilters(budgetCop: 7000)))
        now = now.addingTimeInterval(30)
        XCTAssertNil(cache.value(userID: user, filters: filters))
        cache.insert(snapshot); cache.clear()
        XCTAssertNil(cache.value(userID: user, filters: filters))
    }

    func testFeedReadsTheDurableCatalogAndFiltersItWithoutNetwork() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        let cheap = makeMenu(title: "Cheap")
        let expensive = DailyMenu(title: "Expensive", validUntil: .now.addingTimeInterval(3600), publishedAt: .now.addingTimeInterval(-60),
            establishmentName: "Test", area: "Centro", address: "Test", items: [MenuDish(name: "Dish", priceCop: 30000)], lowestPriceCop: 30000)
        let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil)
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: all,
            response: FeedResponse(fetchedAt: .now, menus: [cheap, expensive])), isCatalog: true)
        h.connectivity.update(isConnected: false)
        h.api.feed = { XCTFail("Offline catalog must not call the network"); return Data() }
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        let feed = FeedViewModel(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock, events: events, content: content)
        await feed.refresh()
        XCTAssertEqual(feed.visibleMenus.map(\.id), [cheap.id])
        XCTAssertEqual(feed.locationMenus.count, 2)
        XCTAssertTrue(feed.isShowingCachedFeed)
        XCTAssertTrue(feed.hasSnapshot)
        XCTAssertNotNil(feed.loadError)
    }

    func testExplicitComplaintAndNumericWaitAreDifferentReportSignals() async throws {
        let h = try await Harness.make()
        let complaint = ReportViewModel(menu: h.menu, kind: .longLine, reports: h.reports)
        await complaint.send()
        let observation = ReportViewModel(menu: h.menu, kind: .longLine, reports: h.reports, waitObservation: true)
        observation.minutes = 5; await observation.send()
        let first = try JSONSerialization.jsonObject(with: h.api.reportBodies[0]) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: h.api.reportBodies[1]) as! [String: Any]
        XCTAssertNil(first["observedWaitMinutes"])
        XCTAssertEqual(second["observedWaitMinutes"] as? Int, 5)
    }

    func testRecommendationAndFiltersIdentifyACopyAsSoonAsNetworkIsLost() async throws {
        let h = try await Harness.make()
        h.api.feed = { try feedData(menu: h.menu) }
        await h.feed.refresh()
        let recommendation = RecommendationViewModel(feed: h.feed), filters = FiltersViewModel(feed: h.feed)
        XCTAssertFalse(recommendation.isShowingCachedFeed)
        h.connectivity.update(isConnected: false)
        XCTAssertTrue(recommendation.isShowingCachedFeed)
        XCTAssertTrue(filters.usesCachedCatalog)
        XCTAssertEqual(recommendation.visibleMenus.count, 1)
        XCTAssertEqual(recommendation.fetchedAt, h.feed.fetchedAt)
    }

    func testCachedFirstLaunchKeepsJuansUpdatingStateUntilFreshFeedArrives() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        let menu = h.menu
        try await content.saveFeed(CachedFeedSnapshot(userId: h.auth.profile.id, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: .now, menus: [menu])))
        let started = expectation(description: "network started")
        var pending: CheckedContinuation<Data, Error>?
        h.api.feed = { try await withCheckedThrowingContinuation { pending = $0; started.fulfill() } }
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        let feed = FeedViewModel(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock, events: events, content: content)
        let load = Task { await feed.refresh() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(feed.isLoading)
        XCTAssertTrue(feed.isShowingCachedFeed)
        XCTAssertEqual(feed.visibleMenus.map(\.id), [menu.id])
        pending?.resume(returning: try feedData(menu: menu))
        // The optional catalog warm-up must not suspend on the test's one-shot continuation.
        h.api.feed = { try feedData(menu: menu) }
        await load.value
        XCTAssertFalse(feed.isLoading)
        XCTAssertFalse(feed.isShowingCachedFeed)
    }

    func testCachedImpressionDoesNotConsumeTheLaterEligiblePilotExposure() async throws {
        let h = try await Harness.make(), menu = h.menu
        h.connectivity.update(isConnected: false)
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        events.accountChanged()
        let key = "unieat.remote.pending-events.\(h.auth.profile.id.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var metadata: ExperimentEventMetadata?
        events.metadataProvider = { _ in metadata }
        events.track("feed_impression", menu: menu); events.track("feed_impression", menu: menu)
        metadata = ExperimentEventMetadata(assignmentId: UUID(), experimentKey: "bq08-wait-v1", variant: "treatment",
            indicatorAvailable: true, indicatorShown: true, source: "live")
        events.track("feed_impression", menu: menu); events.track("feed_impression", menu: menu)
        let rows = try XCTUnwrap(UserDefaultsStore.load([RemoteEvent].self, key: key))
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].metadata)
        XCTAssertEqual(rows[1].metadata, metadata)
        XCTAssertEqual(rows[0].sessionId, rows[1].sessionId)
    }

    func testPilotIsOptInAndControlDoesNotLeakTheWaitInExplanations() async throws {
        let h = try await Harness.make(), sessionID = UUID()
        let pilot = WaitIndicatorPilot(api: h.api, session: h.session, clock: h.clock)
        defer { UserDefaults.standard.removeObject(forKey: "unieat.wait-pilot.\(h.auth.profile.id.uuidString)") }
        XCTAssertFalse(pilot.isEnabled)
        XCTAssertTrue(pilot.showsWaitIndicator)
        h.api.assignmentData = try JSONSerialization.data(withJSONObject: [
            "assignmentId": UUID().uuidString, "sessionId": sessionID.uuidString, "experimentKey": "bq08-wait-v1",
            "variant": "control", "assignedAt": "2026-10-29T12:00:00Z", "serverNow": "2026-10-29T12:00:00Z"])
        pilot.setEnabled(true); await pilot.prepare(sessionID: sessionID)
        XCTAssertFalse(pilot.showsWaitIndicator)
        XCTAssertFalse(pilot.explanation("Precio compatible · fila estimada de 5 min · zona elegida").contains("fila"))
        XCTAssertNil(pilot.metadata(menu: h.menu, sessionID: sessionID, live: false))
        XCTAssertEqual(pilot.metadata(menu: h.menu, sessionID: sessionID, live: true)?.variant, "control")
        pilot.setEnabled(false)
        XCTAssertTrue(pilot.showsWaitIndicator)
        XCTAssertNil(pilot.metadata(menu: h.menu, sessionID: sessionID, live: true))
    }

    // el panel lee los campos nuevos de BQ-04 y sigue funcionando con un back que aun no los manda
    func testBQ04DecodesNewFieldsAndStaysCompatibleWithTheOldBackend() throws {
        let old = Data(#"{"detailRequests":3,"activeShown":2,"expiringShown":0,"expiredShown":1,"closedShown":0,"pendingNoticesShown":0,"confirmedNoticesShown":0}"#.utf8)
        let legacy = try UniEatDates.decoder().decode(BQ04Metrics.self, from: old)
        XCTAssertNil(legacy.rates)
        XCTAssertNil(legacy.unavailableShown)
        let new = Data(#"{"detailRequests":40,"activeShown":30,"expiringShown":6,"expiredShown":3,"closedShown":1,"pendingNoticesShown":4,"confirmedNoticesShown":2,"unavailableShown":4,"distinctMenus":12,"rates":{"active":0.75,"expiring":0.15,"unavailable":0.1,"pendingNotice":0.1,"confirmedNotice":0.05,"revised":0.2}}"#.utf8)
        let current = try UniEatDates.decoder().decode(BQ04Metrics.self, from: new)
        XCTAssertEqual(current.unavailableShown, 4)
        XCTAssertEqual(current.distinctMenus, 12)
        XCTAssertEqual(current.rates?.active, 0.75)
    }

    // la fila habitual llega como dos campos opcionales y una copia vieja sin ellos se sigue leyendo
    func testWaitHistoryIsOptionalAndSurvivesTheMenuCopy() throws {
        let menu = DailyMenu(title: "Almuerzo", validUntil: .now.addingTimeInterval(3600), establishmentName: "Test",
                             area: "Centro", address: "Calle", items: [MenuDish(name: "Plato", priceCop: 10000)], lowestPriceCop: 10000,
                             waitHistoricalMinutes: 15, waitHistoricalSampleCount: 8)
        let data = try UniEatDates.encoder().encode(menu)
        let decoded = try UniEatDates.decoder().decode(DailyMenu.self, from: data)
        XCTAssertEqual(decoded.waitHistoricalMinutes, 15)
        XCTAssertEqual(decoded.replacing(explanation: "otra").waitHistoricalSampleCount, 8)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "waitHistoricalMinutes")
        json.removeValue(forKey: "waitHistoricalSampleCount")
        let old = try UniEatDates.decoder().decode(DailyMenu.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.waitHistoricalMinutes)
    }
}
