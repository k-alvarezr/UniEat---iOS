import XCTest
@testable import UniEatCore

final class UniEatCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func menu(validUntil: Date, publishedAt: Date = Date(timeIntervalSince1970: 9_000),
                      items: [MenuDish] = [MenuDish(name: "Almuerzo", priceCop: 15_000)],
                      waitMinutes: Int? = nil, waitSampleCount: Int = 0,
                      waitNewestReportAt: Date? = nil) -> DailyMenu {
        DailyMenu(title: "Menú del día", validUntil: validUntil, publishedAt: publishedAt,
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

    func testClosedPublicationFromServerStaysClosedBeforeItsExpiry() throws {
        let closed = DailyMenu(title: "Menú cerrado", validUntil: now.addingTimeInterval(3_600),
                               publishedAt: now.addingTimeInterval(-600),
                               closedAt: now.addingTimeInterval(-60),
                               establishmentName: "Café", area: "Centro", address: "Calle 1",
                               items: [MenuDish(name: "Almuerzo", priceCop: 15_000)],
                               lowestPriceCop: 15_000)
        let data = try UniEatDates.encoder().encode(closed)
        let restored = try UniEatDates.decoder().decode(DailyMenu.self, from: data)
        XCTAssertNotNil(restored.closedAt)
        XCTAssertFalse(restored.isActive(at: now))
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
                                       area: "Centro", address: "Calle 1", entranceDescription: "Local 2",
                                       validUntil: now.addingTimeInterval(7_200),
                                       items: original.items, paymentMethods: ["Nequi"], at: now)
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.version, original.version + 1)
        XCTAssertEqual(revised.paymentMethods, ["Nequi"])
        XCTAssertTrue(revised.isActive(at: now.addingTimeInterval(1)))
        let closed = revised.closed(at: now.addingTimeInterval(2))
        XCTAssertFalse(closed.isActive(at: now.addingTimeInterval(2)))
    }

    func testRegistrationRulesEnforceBothMaximumsAndPasswordClasses() {
        XCTAssertNil(RegistrationRules.nameError("Kevin Álvarez"))
        XCTAssertNil(RegistrationRules.nameError(String(repeating: "A", count: 15)))
        XCTAssertNotNil(RegistrationRules.nameError(String(repeating: "A", count: 16)))
        XCTAssertNotNil(RegistrationRules.nameError("   "))
        XCTAssertNil(RegistrationRules.passwordError("Clave123!"))
        XCTAssertNil(RegistrationRules.passwordError("Clave123!" + String(repeating: "x", count: 11)))
        XCTAssertNotNil(RegistrationRules.passwordError("Clave123!" + String(repeating: "x", count: 12)))
        for invalid in ["clave123!", "CLAVE123!", "Claveabc!", "Clave1234", "A1!a"] {
            XCTAssertNotNil(RegistrationRules.passwordError(invalid), invalid)
        }
    }

    func testLocationSuggestionUsesActualMenuCoordinatesAndDistanceLimit() {
        let nearby = DailyMenu(title: "Almuerzo", validUntil: now.addingTimeInterval(3_600),
                               establishmentName: "Local cercano", area: "Norte", address: "Calle 1",
                               latitude: 4.603, longitude: -74.064,
                               items: [MenuDish(name: "Plato", priceCop: 10_000)], lowestPriceCop: 10_000)
        let suggestion = LocationAreaResolver.suggest(latitude: 4.603, longitude: -74.064,
                                                      menus: [nearby])
        XCTAssertEqual(suggestion?.area, "Norte")
        XCTAssertEqual(suggestion?.distanceMeters, 0)
        XCTAssertNil(LocationAreaResolver.suggest(latitude: 5, longitude: -75, menus: [nearby]))
        XCTAssertNil(LocationAreaResolver.suggest(latitude: 100, longitude: 0, menus: [nearby]))
    }

    func testServerPerformanceDecodesSampleAndSuppressedRates() throws {
        let json = Data("""
        {"periodDays":7,"impressions":3,"detailOpens":1,"selections":1,
         "reportedArrivals":0,"savedMenus":1,"locationOpens":1,"reports":0,
         "sampleSize":2,"insufficientData":true,"rates":null}
        """.utf8)
        let summary = try JSONDecoder().decode(PerformanceSummary.self, from: json)
        XCTAssertEqual(summary.sampleSize, 2)
        XCTAssertEqual(summary.savedMenus, 1)
        XCTAssertEqual(summary.locationOpens, 1)
        XCTAssertEqual(summary.insufficientData, true)
        XCTAssertNil(summary.rates)
    }

    // MARK: - BQ-04: detalle del servidor

    private let detailJSON = """
    {"serverNow":"2026-10-01T17:00:00.000Z","fetchedAt":"2026-10-01T17:00:00.000Z","menu":{
      "id":"10000000-0000-4000-8000-000000000003","title":"Almuerzo casero","version":2,"currentVersion":2,
      "validUntil":"2026-10-01T17:20:00.000Z","publishedAt":"2026-10-01T16:00:00.000Z","closedAt":null,
      "establishmentId":"e0000000-0000-4000-8000-000000000003","establishmentName":"Doña Elvira","area":"Norte",
      "address":"Calle 21 #2-15","entranceDescription":"Fachada amarilla","latitude":4.6054,"longitude":-74.0628,
      "photoUrl":null,"paymentMethods":["Efectivo"],"isVerified":false,
      "items":[{"id":"20000000-0000-4000-8000-000000000001","name":"Sopa","description":"","category":"Almuerzo",
                "priceCop":9000,"dietaryTags":["vegetarian"],"dietaryKnown":true}],
      "lowestPriceCop":9000,"waitMinutes":null,"waitSampleCount":1,"waitNewestReportAt":null,"pendingReports":1,
      "status":"expiring","relevanceScore":0,"explanation":"Este menú vence en 30 minutos o menos","hasWaitEvidence":false,
      "reports":[
        {"id":"30000000-0000-4000-8000-000000000001","kind":"price","status":"pending","createdAt":"2026-10-01T16:40:00.000Z","resolvedAt":null},
        {"id":"30000000-0000-4000-8000-000000000002","kind":"unavailable","status":"dismissed","createdAt":"2026-10-01T16:30:00.000Z","resolvedAt":"2026-10-01T16:50:00.000Z"}
      ]}}
    """

    func testMenuDetailDecodesServerStatusVersionAndReports() throws {
        let detail = try UniEatDates.decoder().decode(MenuDetail.self, from: Data(detailJSON.utf8))
        XCTAssertEqual(detail.menu.establishmentName, "Doña Elvira")
        XCTAssertEqual(detail.menu.version, 2)
        XCTAssertEqual(detail.status, .expiring)
        XCTAssertEqual(detail.currentVersion, 2)
        XCTAssertEqual(detail.reports.count, 2)
        // Solo el reporte sin revisar cuenta como pendiente; el descartado no.
        XCTAssertEqual(detail.pendingReports.map(\.kindLabel), ["Precio distinto al publicado"])
        XCTAssertTrue(detail.isNewer(than: 1))
        XCTAssertFalse(detail.isNewer(than: 2))
    }

    func testServerStatusLabelsAndAllowedActions() {
        XCTAssertEqual(ServerPublicationStatus.active.label, "Vigente")
        XCTAssertEqual(ServerPublicationStatus.expiring.label, "Por vencer")
        XCTAssertEqual(ServerPublicationStatus.expired.label, "Vencido")
        XCTAssertEqual(ServerPublicationStatus.closed.label, "Cerrado")
        XCTAssertTrue(ServerPublicationStatus.expiring.acceptsActions)
        XCTAssertFalse(ServerPublicationStatus.expired.acceptsActions)
        XCTAssertFalse(ServerPublicationStatus.closed.acceptsActions)
    }

    func testReportSummaryLabelsUnknownKindWithoutCrashing() {
        let report = ReportSummary(id: UUID(), kind: "otro", status: "confirmed", createdAt: now)
        XCTAssertEqual(report.kindLabel, "Otro cambio")
        XCTAssertEqual(report.statusLabel, "Confirmado")
        XCTAssertFalse(report.isPending)
    }

    func testDetailStatusAdvancesWithClockWhileViewStaysOpen() throws {
        // El JSON de prueba vence a las 17:20 y el servidor lo marcó "Por vencer" a las 17:00.
        let detail = try UniEatDates.decoder().decode(MenuDetail.self, from: Data(detailJSON.utf8))
        let validUntil = detail.menu.validUntil
        XCTAssertEqual(detail.status(at: validUntil.addingTimeInterval(-60)), .expiring)
        XCTAssertTrue(detail.status(at: validUntil.addingTimeInterval(-60)).acceptsActions)
        // Al llegar a la hora de vencimiento pasa a Vencido sin otra consulta.
        XCTAssertEqual(detail.status(at: validUntil), .expired)
        XCTAssertFalse(detail.status(at: validUntil.addingTimeInterval(1)).acceptsActions)
        // Un menú cerrado sigue cerrado aunque falte tiempo para vencer.
        let closed = MenuDetail(menu: detail.menu, status: .closed, currentVersion: 2, reports: [],
                                serverNow: detail.serverNow)
        XCTAssertEqual(closed.status(at: validUntil.addingTimeInterval(-600)), .closed)
    }
}
