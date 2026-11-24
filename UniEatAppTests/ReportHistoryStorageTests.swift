import XCTest
import UniEatCore
@testable import UniEat

/// copia de Mis reportes en swiftdata y preferencias en UserDefaults
@MainActor
final class ReportHistoryStorageTests: XCTestCase {
    private func restaurant(_ id: UUID, name: String = "Ajiaco", total: Int = 2, lastReportAt: Date = .now) -> ReportedRestaurant {
        ReportedRestaurant(establishmentId: id, name: name, area: "Centro", total: total,
                           pending: 1, confirmed: 1, dismissed: 0, lastReportAt: lastReportAt)
    }
    private func entry(_ kind: String = "price") -> UserReport {
        UserReport(id: UUID(), kind: kind, version: 1, menuTitle: "Almuerzo",
                           note: "", observedWaitMinutes: nil, status: "pending", resolutionSource: nil,
                           observedAt: .now, resolvedAt: nil)
    }

    func testPlacesComeBackNewestFirst() throws {
        let database = try LocalDatabase(inMemory: true), user = UUID()
        try database.replaceReportedRestaurants([restaurant(UUID(), name: "Viejo", lastReportAt: .now.addingTimeInterval(-3600)),
                                         restaurant(UUID(), name: "Nuevo")], userId: user)
        XCTAssertEqual(try database.loadReportedRestaurants(userId: user).map(\.name), ["Nuevo", "Viejo"])
    }

    func testListRefreshKeepsSavedReportsAndDropsRestaurantsThatAreGone() throws {
        let database = try LocalDatabase(inMemory: true), user = UUID(), kept = UUID(), gone = UUID()
        try database.replaceReportedRestaurants([restaurant(kept), restaurant(gone)], userId: user)
        try database.replaceUserReports([entry("price")], restaurant: restaurant(kept), userId: user)
        try database.replaceUserReports([entry("unavailable")], restaurant: restaurant(gone), userId: user)
        try database.replaceReportedRestaurants([restaurant(kept, total: 5)], userId: user)
        XCTAssertEqual(try database.loadReportedRestaurants(userId: user).map(\.total), [5], "summary updated, gone removed")
        XCTAssertEqual(try database.loadUserReports(userId: user, establishmentId: kept).map(\.kind), ["price"],
                       "reports of a restaurant that stays are kept")
        XCTAssertTrue(try database.loadUserReports(userId: user, establishmentId: gone).isEmpty, "cascade removes its reports")
    }

    func testDetailReplacesThatRestaurantsReports() throws {
        let database = try LocalDatabase(inMemory: true), user = UUID(), id = UUID()
        try database.replaceUserReports([entry("price"), entry("unavailable")], restaurant: restaurant(id), userId: user)
        try database.replaceUserReports([entry("location")], restaurant: restaurant(id), userId: user)
        XCTAssertEqual(try database.loadUserReports(userId: user, establishmentId: id).map(\.kind), ["location"])
    }

    func testSignOutForgetsOnlyThatAccount() throws {
        let database = try LocalDatabase(inMemory: true), alice = UUID(), bob = UUID()
        try database.replaceReportedRestaurants([restaurant(UUID(), name: "De Alice")], userId: alice)
        try database.replaceReportedRestaurants([restaurant(UUID(), name: "De Bob")], userId: bob)
        try database.deleteReportHistory(userId: alice)
        XCTAssertTrue(try database.loadReportedRestaurants(userId: alice).isEmpty)
        XCTAssertEqual(try database.loadReportedRestaurants(userId: bob).map(\.name), ["De Bob"])
    }

    func testPreferencesArePerAccountAndForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "report-history-tests-\(UUID())"))
        let preferences = ReportHistoryPreferences(defaults: defaults), user = UUID(), other = UUID()
        XCTAssertEqual(preferences.savedFilter(userID: user), .all, "default when nothing was chosen")
        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        preferences.saveFilter(.inReview, userID: user)
        preferences.saveLastSyncDate(synced, userID: user)
        XCTAssertEqual(preferences.savedFilter(userID: user), .inReview)
        XCTAssertEqual(preferences.lastSyncDate(userID: user), synced)
        XCTAssertEqual(preferences.savedFilter(userID: other), .all, "another account keeps its own filter")
        preferences.deleteAll(userID: user)
        XCTAssertEqual(preferences.savedFilter(userID: user), .all)
        XCTAssertNil(preferences.lastSyncDate(userID: user))
    }
}
