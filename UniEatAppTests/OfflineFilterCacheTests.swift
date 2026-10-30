import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class OfflineFilterCacheTests: XCTestCase {
    func testRecentlyUsedFiltersStayWhileTheLeastRecentCombinationIsEvicted() {
        let cache = OfflineFilterCache(capacity: 2), owner = UUID(), now = Date()
        let a = FeedFilters(budgetCop: 10_000), b = FeedFilters(budgetCop: 20_000), c = FeedFilters(budgetCop: 30_000)
        let menus = [makeMenu(title: "Saved")]
        cache.insert(menus, source: menus, userID: owner, filters: a, at: now)
        cache.insert([], source: menus, userID: owner, filters: b, at: now)
        XCTAssertEqual(cache.value(userID: owner, filters: a, at: now)?.count, 1)
        cache.insert(menus, source: menus, userID: owner, filters: c, at: now)
        XCTAssertNil(cache.value(userID: owner, filters: b, at: now))
        XCTAssertNotNil(cache.value(userID: owner, filters: a, at: now))
        XCTAssertNotNil(cache.value(userID: owner, filters: c, at: now))
        XCTAssertNil(cache.value(userID: UUID(), filters: a, at: now))
        cache.clear()
        XCTAssertNil(cache.value(userID: owner, filters: a, at: now))
    }

    func testLocalResultsExpireAtMenuTransitionsAndNeverSurviveClockRollback() {
        let cache = OfflineFilterCache(), owner = UUID(), filters = FeedFilters(), now = Date()
        let menu = DailyMenu(title: "Expiring", validUntil: now.addingTimeInterval(2), publishedAt: now.addingTimeInterval(-60),
            establishmentName: "Fixture", area: "Centro", address: "Fixture", items: [MenuDish(name: "Dish", priceCop: 8_000)], lowestPriceCop: 8_000)
        cache.insert([menu], source: [menu], userID: owner, filters: filters, at: now)
        XCTAssertNotNil(cache.value(userID: owner, filters: filters, at: now.addingTimeInterval(1)))
        XCTAssertNil(cache.value(userID: owner, filters: filters, at: now.addingTimeInterval(2)))
        cache.insert([menu], source: [menu], userID: owner, filters: filters, at: now)
        XCTAssertNil(cache.value(userID: owner, filters: filters, at: now.addingTimeInterval(-1)))
    }

    func testAnEmptyResultExpiresWhenQueueEvidenceChangesOrAFutureMenuStarts() {
        let cache = OfflineFilterCache(), owner = UUID(), now = Date()
        let filters = FeedFilters(budgetCop: nil, availableMinutes: 10, area: "Centro")
        let menu = DailyMenu(title: "Queue", validUntil: now.addingTimeInterval(3_600), publishedAt: now.addingTimeInterval(-60),
            establishmentName: "Fixture", area: "Centro", address: "Fixture", items: [MenuDish(name: "Dish", priceCop: 8_000)],
            lowestPriceCop: 8_000, waitMinutes: 20, waitSampleCount: 3, waitNewestReportAt: now.addingTimeInterval(-1_799))
        cache.insert([], source: [menu], userID: owner, filters: filters, at: now)
        XCTAssertNotNil(cache.value(userID: owner, filters: filters, at: now))
        XCTAssertNil(cache.value(userID: owner, filters: filters, at: now.addingTimeInterval(1)))
        let future = DailyMenu(title: "Future", validUntil: now.addingTimeInterval(3_600), publishedAt: now.addingTimeInterval(5),
            establishmentName: "Fixture", area: "Centro", address: "Fixture", items: [MenuDish(name: "Dish", priceCop: 8_000)], lowestPriceCop: 8_000)
        cache.insert([], source: [future], userID: owner, filters: filters, at: now)
        XCTAssertNil(cache.value(userID: owner, filters: filters, at: now.addingTimeInterval(5)))
    }
}
