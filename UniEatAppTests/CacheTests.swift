import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class CacheTests: XCTestCase {
    // con 20 detalles guardados, abrir el 21 bota el que se uso hace mas tiempo
    func testDetailMemoryKeepsTheTwentyMostRecent() {
        let memory = DetailMemoryCache(), owner = UUID()
        let details = (0..<21).map { _ in makeDetail(serverNow: .now) }
        for detail in details.prefix(20) { memory.insert(detail, userID: owner) }
        XCTAssertNotNil(memory.value(userID: owner, menuID: details[0].menu.id))   // se abre el primero otra vez
        memory.insert(details[20], userID: owner)                                   // el 21 bota al segundo, no al primero
        XCTAssertNotNil(memory.value(userID: owner, menuID: details[0].menu.id))
        XCTAssertNil(memory.value(userID: owner, menuID: details[1].menu.id))
        XCTAssertNotNil(memory.value(userID: owner, menuID: details[20].menu.id))
        XCTAssertEqual(memory.count, 20)
    }

    // guardar el mismo detalle otra vez lo reemplaza, no suma una entrada
    func testDetailMemoryReplacingKeepsTheCount() {
        let memory = DetailMemoryCache(), owner = UUID(), detail = makeDetail(serverNow: .now)
        memory.insert(detail, userID: owner)
        memory.insert(detail, userID: owner)
        XCTAssertEqual(memory.count, 1)
    }

    // el detalle dura 60 s en memoria y es por usuario
    func testDetailMemoryExpiresAndIsPerUser() {
        var now = Date(timeIntervalSince1970: 1_000)
        let memory = DetailMemoryCache(now: { now })
        let owner = UUID(), detail = makeDetail(serverNow: now)
        memory.insert(detail, userID: owner)
        XCTAssertNotNil(memory.value(userID: owner, menuID: detail.menu.id))
        XCTAssertNil(memory.value(userID: UUID(), menuID: detail.menu.id), "otra cuenta no ve el detalle")
        now = now.addingTimeInterval(61)
        XCTAssertNil(memory.value(userID: owner, menuID: detail.menu.id), "a los 60 s vence")
    }

    // Mis reportes: con 2 restaurantes guardados, abrir el 3ro bota el que se uso hace mas tiempo
    func testReportedRestaurantMemoryKeepsTheTwoMostRecent() {
        let memory = ReportedRestaurantMemoryCache(), owner = UUID()
        let a = makeSnapshot("A"), b = makeSnapshot("B"), c = makeSnapshot("C")
        memory.insert(a, userID: owner)
        memory.insert(b, userID: owner)
        XCTAssertNotNil(memory.value(userID: owner, establishmentID: a.restaurant.establishmentId))   // se vuelve a abrir A
        memory.insert(c, userID: owner)                                                               // C bota a B, no a A
        XCTAssertNotNil(memory.value(userID: owner, establishmentID: a.restaurant.establishmentId))
        XCTAssertNil(memory.value(userID: owner, establishmentID: b.restaurant.establishmentId))
        XCTAssertNotNil(memory.value(userID: owner, establishmentID: c.restaurant.establishmentId))
        XCTAssertEqual(memory.count, 2)
    }

    // guardar el mismo restaurante otra vez lo reemplaza, no suma una entrada
    func testReportedRestaurantMemoryReplacingKeepsTheCount() {
        let memory = ReportedRestaurantMemoryCache(), owner = UUID(), a = makeSnapshot("A")
        memory.insert(a, userID: owner)
        memory.insert(a, userID: owner)
        XCTAssertEqual(memory.count, 1)
    }

    // es por usuario y se borra al cambiar de cuenta
    func testReportedRestaurantMemoryIsPerUserAndClears() {
        let memory = ReportedRestaurantMemoryCache(), owner = UUID(), a = makeSnapshot("A")
        memory.insert(a, userID: owner)
        XCTAssertNil(memory.value(userID: UUID(), establishmentID: a.restaurant.establishmentId), "otra cuenta no lo ve")
        memory.clear()
        XCTAssertNil(memory.value(userID: owner, establishmentID: a.restaurant.establishmentId))
        XCTAssertEqual(memory.count, 0)
    }

    // el panel queda por periodo y se borra al cambiar de cuenta
    func testPanelMemoryKeepsEachPeriodAndClears() {
        let panels = PanelMemoryCache<String>()
        panels.insert("semana", days: 7)
        panels.insert("mes", days: 28)
        XCTAssertEqual(panels.value(days: 7), "semana")
        XCTAssertEqual(panels.value(days: 28), "mes")
        panels.clear()
        XCTAssertNil(panels.value(days: 7))
    }

    private func makeDetail(serverNow: Date) -> MenuDetail {
        let menu = DailyMenu(title: "Almuerzo", validUntil: .now.addingTimeInterval(3600), establishmentName: "Test",
                             area: "Centro", address: "Calle", items: [MenuDish(name: "Plato", priceCop: 10000)], lowestPriceCop: 10000)
        return MenuDetail(menu: menu, status: .active, currentVersion: 1, reports: [], serverNow: serverNow)
    }

    private func makeSnapshot(_ name: String) -> ReportedRestaurantSnapshot {
        let restaurant = ReportedRestaurant(establishmentId: UUID(), name: name, area: "Centro", total: 1,
                                            pending: 1, confirmed: 0, dismissed: 0, lastReportAt: .now)
        return ReportedRestaurantSnapshot(restaurant: restaurant, reports: [], lastSyncDate: .now)
    }
}
