import XCTest
import SwiftData
import UIKit
import ImageIO
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
            response: FeedResponse(fetchedAt: .now, menus: [cheap, expensive]), timeReference: h.clock.snapshot()), isCatalog: true)
        h.connectivity.update(isConnected: false)
        h.api.feed = { XCTFail("Offline catalog must not call the network"); return Data() }
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        let feed = FeedViewModel(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock, events: events, content: content)
        await feed.refresh()
        XCTAssertEqual(feed.visibleMenus.map(\.id), [cheap.id])
        XCTAssertEqual(feed.locationMenus.count, 2)
        XCTAssertTrue(feed.isShowingCachedFeed)
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

    func testThumbnailChildrenAreBoundedDownsampledAndAvailableAsHashedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1500)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
        }.pngData()!
        let counter = ImageRequestCounter()
        let images = FeedImageStore(directory: directory) { _ in
            await counter.begin()
            try await Task.sleep(for: .milliseconds(20))
            await counter.end()
            return image
        }
        let menus = (0..<8).map { i in
            DailyMenu(title: "Photo", validUntil: .now.addingTimeInterval(3600), establishmentName: "Test", area: "Centro", address: "Test",
                photoUrl: "https://example.invalid/photo-\(i).png", items: [], lowestPriceCop: 1)
        }
        let count = await images.prefetch(menus)
        let peak = await counter.peak
        XCTAssertEqual(count, 8)
        XCTAssertLessThanOrEqual(peak, 4)
        let url = URL(string: menus[0].photoUrl!)!
        let file = await images.localFile(url)
        XCTAssertEqual(file?.lastPathComponent, FeedImageStore.filename(url))
        let source = CGImageSourceCreateWithURL(file! as CFURL, nil)!
        let thumbnail = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 720)
    }
}

private actor ImageRequestCounter {
    private var active = 0
    private(set) var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}
