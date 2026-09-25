import XCTest
@testable import UniEatCore

final class UniEatCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func menu(validUntil: Date, publishedAt: Date = Date(timeIntervalSince1970: 9_000),
                      items: [MenuDish] = [MenuDish(name: "Almuerzo", priceCop: 15_000)],
                      waitMinutes: Int? = nil, waitSampleCount: Int = 0,
                      waitNewestReportAt: Date? = nil) -> Menu {
        Menu(title: "Menú del día", validUntil: validUntil, publishedAt: publishedAt,
             establishmentName: "Café", area: "Centro", address: "",
             items: items, lowestPriceCop: items.map(\.priceCop).min() ?? 0,
             waitMinutes: waitMinutes, waitSampleCount: waitSampleCount,
             waitNewestReportAt: waitNewestReportAt)
    }

    func testExpiryAndFuturePublicationHideMenu() {
        let expired = menu(validUntil: now)
        let future = menu(validUntil: now.addingTimeInterval(3_600),
                          publishedAt: now.addingTimeInterval(60))
        XCTAssertFalse(expired.isActive(at: now))
        XCTAssertFalse(future.isActive(at: now))
        XCTAssertEqual(PublicationAssessment(menu: expired, at: now).state, .expired)
    }

    func testQueueNeedsThreeRecentReports() {
        let until = now.addingTimeInterval(3_600)
        XCTAssertFalse(menu(validUntil: until, waitMinutes: 8, waitSampleCount: 2,
                            waitNewestReportAt: now).hasWaitEvidence(at: now))
        XCTAssertFalse(menu(validUntil: until, waitMinutes: 8, waitSampleCount: 3,
                            waitNewestReportAt: now.addingTimeInterval(-1_801)).hasWaitEvidence(at: now))
        XCTAssertTrue(menu(validUntil: until, waitMinutes: 8, waitSampleCount: 3,
                           waitNewestReportAt: now.addingTimeInterval(-300)).hasWaitEvidence(at: now))
    }

    func testContextualRankingRequiresOneAffordableDietCompatibleDish() {
        let until = now.addingTimeInterval(3_600)
        let mismatch = menu(validUntil: until, items: [
            MenuDish(name: "Vegetariano caro", priceCop: 25_000,
                     dietaryTags: ["vegetarian"], dietaryKnown: true),
            MenuDish(name: "Carne barata", priceCop: 10_000, dietaryKnown: true)
        ])
        let match = menu(validUntil: until, items: [
            MenuDish(name: "Vegetariano", priceCop: 12_000,
                     dietaryTags: ["vegetarian"], dietaryKnown: true)
        ])
        let filters = FeedFilters(budgetCop: 15_000, diet: "vegetarian")
        let result = ContextualRankingStrategy().ranked([mismatch, match], for: filters, at: now)
        XCTAssertEqual(result.map(\.id), [match.id])
        XCTAssertTrue(ContextualRankingStrategy().explanation(for: match, filters: filters, at: now)
            .contains("Vegetariano por $12000 COP"))
    }

    func testKnownLongWaitExceedsTimeBudget() {
        let until = now.addingTimeInterval(3_600)
        let slow = menu(validUntil: until, waitMinutes: 30, waitSampleCount: 3,
                        waitNewestReportAt: now.addingTimeInterval(-300))
        let result = ContextualRankingStrategy().ranked([slow],
            for: FeedFilters(availableMinutes: 20, area: "Centro"), at: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testRestaurantRevisionKeepsIdentityAndClosingExpiresPublication() {
        let original = menu(validUntil: now.addingTimeInterval(3_600))
        let revised = original.revised(title: "Nuevo almuerzo", establishmentName: "Café",
                                       area: "Centro", address: "Calle 1", validUntil: now.addingTimeInterval(7_200),
                                       items: original.items, at: now)
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.version, original.version + 1)
        XCTAssertTrue(revised.isActive(at: now.addingTimeInterval(1)))
        let closed = revised.closed(at: now.addingTimeInterval(2))
        XCTAssertFalse(closed.isActive(at: now.addingTimeInterval(2)))
    }
}
