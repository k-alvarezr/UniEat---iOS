import XCTest
@testable import UniEatCore

final class OfflineMenuFilteringTests: XCTestCase {
    func testBudgetAndDietMustMatchTheSameDishEvenOffline() {
        let now = Date(timeIntervalSince1970: 1000)
        let menu = DailyMenu(title: "Mixed", validUntil: now.addingTimeInterval(3600), publishedAt: now.addingTimeInterval(-60),
            establishmentName: "Test", area: "Centro", address: "Test", items: [
                MenuDish(name: "Cheap", priceCop: 8000),
                MenuDish(name: "Vegan", priceCop: 30000, dietaryTags: ["vegan"], dietaryKnown: true)], lowestPriceCop: 8000)
        XCTAssertTrue(OfflineMenuFiltering.filter([menu], filters: FeedFilters(budgetCop: 15000, diet: "vegan"), at: now).isEmpty)
        let matches = OfflineMenuFiltering.filter([menu], filters: FeedFilters(budgetCop: 35000, diet: "vegan"), at: now)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches[0].explanation.contains("copia"))
        XCTAssertTrue(OfflineMenuFiltering.filter([menu], filters: FeedFilters(budgetCop: 35000, diet: "vegan"), at: now.addingTimeInterval(3601)).isEmpty)
    }
}
