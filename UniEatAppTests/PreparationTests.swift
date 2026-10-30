import XCTest
import UniEatCore
@testable import UniEat

/// Regression tests for the cross-screen/session boundaries changed by this preparation.
@MainActor
final class PreparationTests: XCTestCase {
    func testServerClockUsesServerTimeEvenIfThePhoneClockIsWrong() {
        // el celular dice una hora muy distinta a la del server
        var wall = Date(timeIntervalSince1970: 5_000_000)
        let clock = ServerClock(wallTime: { wall })
        let server = Date(timeIntervalSince1970: 1_000)
        clock.synchronize(server)
        XCTAssertEqual(clock.now, server)
        // pasa un minuto en el celular, la hora sigue la del server
        wall = wall.addingTimeInterval(60)
        XCTAssertEqual(clock.now, server.addingTimeInterval(60))
    }

    func testExpiredSessionKeepsLocalDataButManualSignOutForgetsIt() async throws {
        let h = try await Harness.make()
        let userID = h.auth.profile.id
        var forgotten: [UUID] = []
        h.session.onForget = { forgotten.append($0) }
        h.connectivity.update(isConnected: false)
        _ = try await h.reports.submitReport(for: h.menu, kind: .price, note: "", waitMinutes: nil)
        // la sesion vencio sola: no se borra nada, el reporte espera a que vuelva a entrar
        h.session.signOut(message: "Tu sesión terminó.")
        XCTAssertTrue(forgotten.isEmpty)
        XCTAssertEqual(try h.database.pending(userID: userID).count, 1)
        // a mano: se avisa a AppStore con el id de la cuenta y la base borra sus reportes
        try await h.session.signIn(email: "test@example.invalid", password: "test")
        h.session.signOut(forgetData: true)
        XCTAssertEqual(forgotten, [userID])
        // la copia del feed de la cuenta tambien se borra
        let content = LocalContentService(container: h.database.container)
        let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
        try await content.saveFeed(CachedFeedSnapshot(userId: userID, filters: all,
            response: FeedResponse(fetchedAt: .now, menus: [h.menu])), isCatalog: true)
        try h.database.deleteAll(userId: userID)
        XCTAssertEqual(try h.database.pending(userID: userID).count, 0)
        let catalog = try await content.feed(userID: userID, filters: all, catalog: true)
        XCTAssertNil(catalog)
    }

    func testReportRetriesKeepIdentityObservationTimeAndOnlyDeleteAfterAcknowledgement() async throws {
        let h = try await Harness.make()
        let observed = Date(timeIntervalSince1970: 1_000)
        h.clock.synchronize(observed)
        h.api.failure = APIFailure(code: "RATE_LIMITED", message: "Espera")
        let status = try await h.reports.submitReport(for: h.menu, kind: .longLine, note: "", waitMinutes: 15)
        XCTAssertEqual(status, .queued)
        let before = try h.database.pending(userID: h.auth.profile.id)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before[0].body.observedAt!.timeIntervalSince1970, observed.timeIntervalSince1970, accuracy: 1)
        h.api.failure = APIFailure(code: "INTERNAL_ERROR", message: "Temporal")
        await h.reports.flushReports()
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).count, 1)
        h.api.failure = nil
        await h.reports.flushReports()
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).count, 0)
        let ids = try h.api.reportBodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        XCTAssertEqual(Set(ids.compactMap { $0["clientReportId"] as? String }).count, 1)
        XCTAssertEqual(Set(ids.compactMap { $0["observedAt"] as? String }).count, 1)
    }

    func testPermanentRejectionRemainsInSwiftDataForReview() async throws {
        let h = try await Harness.make()
        h.api.failure = APIFailure(code: "VALIDATION_ERROR", message: "Revisa el reporte")
        let status = try await h.reports.submitReport(for: h.menu, kind: .price, note: "", waitMinutes: nil)
        XCTAssertEqual(status, .needsReview)
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).count, 1)
        XCTAssertNotNil(h.reports.syncMessage)
        // el motivo queda en la misma fila de swiftdata y se cuenta aparte de los que esperan red
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).first?.rejectedReason, "Revisa el reporte")
        XCTAssertEqual(h.reports.needsReviewCount, 1)
        XCTAssertEqual(h.reports.pendingReportCount, 0)
        let attempts = h.api.reportBodies.count
        await h.reports.flushReports()
        XCTAssertEqual(h.api.reportBodies.count, attempts, "Rejected rows wait for an explicit retry")
        h.api.failure = nil
        await h.reports.flushReports(retryRejected: true)
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).count, 0)
    }

    func testSwiftDataRelationshipKeepsEachUsersMenuVersionAndOriginalReportID() throws {
        let db = try LocalDatabase(inMemory: true)
        let first = UUID(), second = UUID(), reportID = UUID()
        let menu = makeMenu(title: "Original", version: 2)
        try db.enqueue(userID: first, menu: menu, kind: .price, note: "Precio", waitMinutes: nil,
                       id: reportID, observedAt: Date(timeIntervalSince1970: 100))
        try db.enqueue(userID: second, menu: menu, kind: .location, note: "Entrada", waitMinutes: nil,
                       id: UUID(), observedAt: .now)
        let own = try db.pending(userID: first)
        XCTAssertEqual(own.count, 1)
        XCTAssertEqual(own[0].id, reportID)
        XCTAssertEqual(own[0].body.version, 2)
        XCTAssertEqual(own[0].body.clientReportId, reportID)
        try db.acknowledge(id: reportID, userID: second)
        XCTAssertEqual(try db.pending(userID: first).count, 1, "Another account cannot acknowledge this row")
        try db.acknowledge(id: reportID, userID: first)
        XCTAssertEqual(try db.pending(userID: first).count, 0)
        XCTAssertEqual(try db.pending(userID: second).count, 1)
    }

    func testStorageFailureNeverClaimsReportWasQueued() async throws {
        let h = try await Harness.make()
        let facade = ReportingFacade(api: h.api, outbox: nil, session: h.session,
            connectivity: h.connectivity, clock: h.clock)
        do {
            _ = try await facade.submitReport(for: h.menu, kind: .price, note: "", waitMinutes: nil)
            XCTFail("Must report the storage failure")
        } catch let failure as APIFailure { XCTAssertEqual(failure.code, "LOCAL_STORAGE_ERROR") }
        XCTAssertTrue(h.api.reportBodies.isEmpty)
    }

    func testReportChildrenCannotSendAnotherUsersPendingRowsAfterSignOut() async throws {
        let h = try await Harness.make()
        h.connectivity.update(isConnected: false)
        for _ in 0..<3 {
            _ = try await h.reports.submitReport(for: h.menu, kind: .price, note: "", waitMinutes: nil)
        }
        h.connectivity.update(isConnected: true)
        h.api.onReport = { h.session.signOut() }
        await h.reports.flushReports()
        XCTAssertEqual(h.api.reportBodies.count, 1, "The remaining child tasks must fail their session preflight")
        XCTAssertEqual(try h.database.pending(userID: h.auth.profile.id).count, 3,
                       "Even the in-flight row is retained for an idempotent retry by its owner")
    }

    func testLateFeedResponseAfterSignOutCannotRestorePreviousAccountData() async throws {
        let h = try await Harness.make()
        let started = expectation(description: "feed started")
        var continuation: CheckedContinuation<Data, Error>?
        h.api.feed = {
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }
        let load = Task { await h.feed.refresh() }
        await fulfillment(of: [started], timeout: 2)
        h.session.signOut()
        h.feed.accountChanged()
        continuation?.resume(returning: try feedData(menu: h.menu))
        await load.value
        XCTAssertTrue(h.feed.menus.isEmpty)
        XCTAssertNil(h.feed.loadError)
    }

    func testLatestRefreshWinsEvenWithIdenticalFilters() async throws {
        let h = try await Harness.make()
        let first = expectation(description: "first"), second = expectation(description: "second")
        var pending: [CheckedContinuation<Data, Error>] = []
        h.api.feed = {
            try await withCheckedThrowingContinuation { c in
                pending.append(c)
                if pending.count == 1 { first.fulfill() } else { second.fulfill() }
            }
        }
        let old = Task { await h.feed.refresh() }
        await fulfillment(of: [first], timeout: 2)
        let new = Task { await h.feed.refresh() }
        await fulfillment(of: [second], timeout: 2)
        pending[1].resume(returning: try feedData(menu: makeMenu(title: "New")))
        await new.value
        pending[0].resume(returning: try feedData(menu: makeMenu(title: "Old")))
        await old.value
        XCTAssertEqual(h.feed.menus.first?.title, "New")
    }

    func testFeedServerErrorIsVisibleAndDifferentFromAnEmptySuccessfulResult() async throws {
        let h = try await Harness.make()
        h.api.feed = { throw APIFailure(code: "INTERNAL_ERROR", message: "Servidor temporalmente no disponible") }
        await h.feed.refresh()
        XCTAssertNotNil(h.feed.loadError)
        h.api.feed = { try UniEatDates.encoder().encode(FeedResponse(fetchedAt: .now, menus: [])) }
        await h.feed.refresh()
        XCTAssertNil(h.feed.loadError)
        XCTAssertFalse(h.feed.isShowingCachedFeed)
        XCTAssertTrue(h.feed.menus.isEmpty)
    }
}

@MainActor
final class FakeAuth: SessionAuthenticating {
    let profile = Profile(displayName: "Test", role: "student")
    func signIn(email: String, password: String) async throws -> Profile { profile }
    func signUp(email: String, password: String, name: String) async throws -> Profile? { profile }
    func restore() async -> Profile? { nil }
    func signOut() { }
}

@MainActor
final class FakeAPI: APIRequesting {
    let userID: UUID
    var failure: APIFailure?
    var reportBodies: [Data] = []
    var onReport: (() -> Void)?
    var assignmentData: Data?
    var feed: (() async throws -> Data)?
    init(userID: UUID) { self.userID = userID }
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        let data: Data
        switch path {
        case "me": data = Data("{\"id\":\"\(userID)\",\"displayName\":\"Test\",\"role\":\"student\",\"establishments\":[]}".utf8)
        case "establishments/mine": data = Data("{\"establishments\":[]}".utf8)
        case "feed": data = try await feed?() ?? UniEatDates.encoder().encode(FeedResponse(fetchedAt: .now, menus: []))
        default: throw APIFailure.unexpected
        }
        return try UniEatDates.decoder().decode(Response.self, from: data)
    }
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
        query: [URLQueryItem], body: Body?) async throws -> Response {
        if path == "experiments/bq08/assignment", let assignmentData {
            return try UniEatDates.decoder().decode(Response.self, from: assignmentData)
        }
        if let body { reportBodies.append(try UniEatDates.encoder().encode(body)) }
        onReport?()
        if let failure { throw failure }
        return try JSONDecoder().decode(Response.self, from: Data("{\"status\":\"observation\"}".utf8))
    }
}

@MainActor
struct Harness {
    let auth: FakeAuth
    let api: FakeAPI
    let session: SessionStore
    let database: LocalDatabase
    let reports: ReportingFacade
    let connectivity: ConnectivityService
    let clock: ServerClock
    let feed: FeedViewModel
    var menu: DailyMenu { makeMenu(title: "Test") }
    static func make() async throws -> Harness {
        let auth = FakeAuth(), api = FakeAPI(userID: auth.profile.id)
        let session = SessionStore(auth: auth, api: api)
        try await session.signIn(email: "test@example.invalid", password: "test")
        let connectivity = ConnectivityService(monitorNetwork: false), clock = ServerClock()
        let database = try LocalDatabase(inMemory: true)
        let reports = ReportingFacade(api: api, outbox: database, session: session, connectivity: connectivity, clock: clock)
        let events = EventService(api: api, session: session, connectivity: connectivity, clock: clock)
        let feed = FeedViewModel(api: api, session: session, connectivity: connectivity, clock: clock, events: events)
        return Harness(auth: auth, api: api, session: session, database: database, reports: reports,
                        connectivity: connectivity, clock: clock, feed: feed)
    }
}

func makeMenu(title: String, version: Int = 1) -> DailyMenu {
    DailyMenu(title: title, version: version, validUntil: .now.addingTimeInterval(3600), publishedAt: .now.addingTimeInterval(-60),
        establishmentName: "Test", area: "Centro", address: "Test", items: [MenuDish(name: "Dish", priceCop: 10000)], lowestPriceCop: 10000)
}
func feedData(menu: DailyMenu) throws -> Data {
    try UniEatDates.encoder().encode(FeedResponse(fetchedAt: .now, menus: [menu], serverNow: .now))
}
