import XCTest
import UniEatCore
@testable import UniEat

/// Escenarios de pérdida/recuperación y límites de sesión; no sustituyen la prueba física en iPhone.
@MainActor
final class OfflineScreenTests: XCTestCase {
    func testNetworkPathAndServiceAvailabilityHaveDifferentMessages() {
        let network = ConnectivityService(monitorNetwork: false)
        network.serviceResponded(false)
        XCTAssertEqual(network.issue, .serviceUnavailable)
        network.update(isConnected: false)
        XCTAssertEqual(network.issue, .noInternet)
        network.update(isConnected: true)
        XCTAssertNil(network.issue)
    }

    func testRecoveryProbeIsSharedAndDoesNotRunWithoutANetworkPath() async {
        let network = ConnectivityService(monitorNetwork: false)
        let started = expectation(description: "probe")
        var continuation: CheckedContinuation<Void, Error>?
        var calls = 0
        network.checkService = {
            calls += 1
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }
        let first = Task { await network.retry() }
        await fulfillment(of: [started], timeout: 2)
        await network.retry()
        XCTAssertTrue(network.isChecking)
        XCTAssertEqual(calls, 1)
        continuation?.resume(throwing: URLError(.cannotConnectToHost))
        await first.value
        XCTAssertFalse(network.isChecking)
        XCTAssertEqual(network.issue, .serviceUnavailable)
        network.update(isConnected: false)
        await network.retry()
        XCTAssertEqual(calls, 1)
        network.update(isConnected: true)
        network.checkService = { calls += 1 }
        await network.retry()
        XCTAssertNil(network.issue)
        XCTAssertEqual(calls, 2)
    }

    func testPublicHealthProbeDoesNotReadOrSendAnAccessToken() async throws {
        let transport = transport()
        defer { transport.invalidateAndCancel() }
        var tokenReads = 0
        let api = APIClient(configuration: configuration, session: transport) {
            tokenReads += 1
            throw AuthFailure.expired
        }
        try await api.checkHealth()
        XCTAssertEqual(tokenReads, 0)
    }

    func testTransportAndServerFailuresUpdateAvailabilityAndSuccessRecoversIt() async throws {
        let transport = transport()
        defer { transport.invalidateAndCancel() }
        let api = APIClient(configuration: configuration, session: transport) { "fixture-token" }
        var availability: [Bool] = []
        api.onServiceAvailability = { availability.append($0) }
        do {
            let _: Ping = try await api.get("failure")
            XCTFail("Network failure must be visible")
        } catch let error as APIFailure { XCTAssertEqual(error.code, "OFFLINE") }
        let _: Ping = try await api.get("ok")
        do {
            let _: Ping = try await api.get("server-error")
            XCTFail("503 must not count as an available service")
        } catch let error as APIFailure { XCTAssertEqual(error.code, "INTERNAL_ERROR") }
        XCTAssertEqual(availability, [false, true, false])
    }

    func testCancellationDoesNotAnnounceAServiceFailure() async {
        let transport = transport()
        defer { transport.invalidateAndCancel() }
        let api = APIClient(configuration: configuration, session: transport) { "fixture-token" }
        var changes = 0
        api.onServiceAvailability = { _ in changes += 1 }
        do {
            let _: Ping = try await api.get("cancelled")
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(changes, 0)
    }

    func testAnExpiredOldTokenCannotSignOutTheNewIdentity() async {
        var identity = UUID()
        let api = APIClient(configuration: configuration, sessionIdentity: { identity }) {
            identity = UUID()
            throw AuthFailure.expired
        }
        var invalidations = 0
        api.onUnauthorized = { invalidations += 1 }
        do {
            let _: Ping = try await api.get("ok")
            XCTFail("Expected old identity cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(invalidations, 0)
    }

    func testLoginPreservesTheFormAndDoesNotStartAuthenticationOffline() async {
        let auth = FakeAuth(), api = ScreenAPI()
        let session = SessionStore(auth: auth, api: api)
        let network = ConnectivityService(monitorNetwork: false)
        network.update(isConnected: false)
        let model = AuthViewModel(session: session, connectivity: network)
        model.email = "fixture@example.invalid"
        model.password = "fixture-password"
        await model.submit()
        XCTAssertNil(session.profile)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(model.email, "fixture@example.invalid")
        XCTAssertEqual(model.password, "fixture-password")
        XCTAssertTrue(api.paths.isEmpty)
    }

    func testColdOfflineMetricsDoNotStartASpinnerOrRequest() async throws {
        let h = try await roleHarness(), model = h.performance
        h.network.update(isConnected: false)
        h.api.paths = []
        await model.loadPerformance(days: 7)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.adminDashboard.isEmpty)
        XCTAssertTrue(h.api.paths.isEmpty)
    }

    func testOfflinePublicationsDoNotClaimThatAnUnloadedListIsEmpty() async throws {
        let h = try await roleHarness(role: "restaurant"), clock = ServerClock()
        let files = FileStore()
        let events = EventService(api: h.api, session: h.session, connectivity: h.network, clock: clock)
        let feed = FeedViewModel(api: h.api, session: h.session, connectivity: h.network, clock: clock, events: events)
        let model = PublishViewModel(service: PublishService(api: h.api, session: h.session, files: files),
            feed: feed, session: h.session, connectivity: h.network, clock: clock)
        h.network.update(isConnected: false)
        h.api.paths = []
        await model.refresh()
        XCTAssertFalse(model.hasLoadedOwnMenus)
        XCTAssertFalse(model.isRefreshingOwnMenus)
        XCTAssertTrue(h.api.paths.isEmpty)
        h.network.update(isConnected: true)
        await model.refresh()
        XCTAssertTrue(model.hasLoadedOwnMenus)
        XCTAssertTrue(model.ownMenus.isEmpty)
        XCTAssertEqual(h.api.paths, ["menus/mine"])
    }

    func testColdAccountCopyPreservesNavigationButCannotAuthorizeAdminActions() async throws {
        let h = try await roleHarness()
        defer { UserDefaultsStore.remove(key: SessionStore.accountCacheKey(h.api.userID)) }
        let auth = FakeAuth()
        // Supabase Auth siempre devuelve student; /me es quien certifica el rol real.
        auth.profile = Profile(id: h.api.userID, displayName: "Auth metadata", role: "student")
        h.api.accountUnavailable = true
        let restored = SessionStore(auth: auth, api: h.api)
        try await restored.signIn(email: "fixture@example.invalid", password: "fixture")
        XCTAssertTrue(restored.isAdmin, "The previously verified role is usable only for local navigation")
        XCTAssertFalse(restored.isAccountVerified)
        XCTAssertNotNil(restored.cachedAccountDate)
        XCTAssertThrowsError(try restored.requireAdmin())
        h.api.accountUnavailable = false
        h.api.role = "student"
        try await restored.refreshAccount()
        XCTAssertTrue(restored.isAccountVerified)
        XCTAssertFalse(restored.isAdmin, "The server's role replaces the old display copy")
    }

    func testCachedAccountCannotBeReadByAnotherIdentityAndManualLogoutRemovesIt() async throws {
        let h = try await roleHarness()
        let other = UUID(), key = SessionStore.accountCacheKey(other)
        defer { UserDefaultsStore.remove(key: key) }
        UserDefaultsStore.save(CachedAccountSnapshot(profile: h.session.profile!, memberships: [],
            establishments: [], savedAt: .now), key: key)
        let auth = FakeAuth()
        auth.profile = Profile(id: other, displayName: "Other", role: "student")
        h.api.accountUnavailable = true
        let otherSession = SessionStore(auth: auth, api: h.api)
        try await otherSession.signIn(email: "other@example.invalid", password: "fixture")
        XCTAssertFalse(otherSession.isAdmin)
        XCTAssertNil(otherSession.cachedAccountDate)
        XCTAssertNotNil(UserDefaultsStore.load(CachedAccountSnapshot.self, key: SessionStore.accountCacheKey(h.api.userID)))
        await h.session.signOutAndForget()
        XCTAssertNil(UserDefaultsStore.load(CachedAccountSnapshot.self, key: SessionStore.accountCacheKey(h.api.userID)))
    }

    func testMetricsKeepTheLastPeriodAndCanRetryWhenOnlyTheServiceWasUnreachable() async throws {
        let h = try await roleHarness(), model = h.performance
        h.network.serviceResponded(false)
        await model.loadPerformance(days: 7)
        XCTAssertNotNil(model.adminDashboard[7], "A retry must be possible while a network path exists")
        h.network.update(isConnected: false)
        h.api.paths = []
        await model.loadPerformance(days: 28)
        XCTAssertNotNil(model.adminDashboard[7])
        XCTAssertNil(model.adminDashboard[28], "Another period must not be presented as the selected one")
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(h.api.paths.isEmpty)
    }

    func testMetricsDropAResponseAfterNetworkLossAndRecoverAfterReconnect() async throws {
        let h = try await roleHarness()
        let started = expectation(description: "dashboard")
        var continuation: CheckedContinuation<Data, Error>?
        h.api.dashboard = {
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }
        let load = Task { await h.performance.loadPerformance(days: 7) }
        await fulfillment(of: [started], timeout: 2)
        h.network.update(isConnected: false)
        continuation?.resume(returning: try dashboardData())
        await load.value
        XCTAssertNil(h.performance.adminDashboard[7])
        XCTAssertFalse(h.performance.isLoading)
        h.api.dashboard = nil
        h.network.update(isConnected: true)
        await h.performance.loadPerformance(days: 7)
        XCTAssertNotNil(h.performance.adminDashboard[7])
    }

    func testAdministrativeWritesAreBlockedOfflineEvenIfCalledOutsideTheView() async throws {
        let h = try await roleHarness()
        let service = AccountService(api: h.api, session: h.session, connectivity: h.network)
        h.network.update(isConnected: false)
        h.api.paths = []
        await assertOffline {
            try await service.setAdminRole(for: AdminUser(id: UUID(), displayName: "Other", role: "student"), enabled: true)
        }
        await assertOffline {
            try await service.approveMembership(PendingMembership(establishmentId: UUID(), establishmentName: "Fixture",
                area: "Centro", userId: UUID(), displayName: "Fixture"))
        }
        await assertOffline {
            try await service.requestEstablishment(EstablishmentRequestBody(name: "Fixture", area: "Centro",
                address: "Fixture", entranceDescription: "", paymentMethods: ["Efectivo"], photoUrl: nil,
                latitude: nil, longitude: nil))
        }
        XCTAssertTrue(h.api.paths.isEmpty)
        XCTAssertTrue(h.session.isAdmin, "No local permission change is inferred from an attempted write")
    }

    func testAnUnavailableApprovalListIsDifferentFromAnEmptyDownloadedList() async throws {
        let h = try await roleHarness()
        let service = AccountService(api: h.api, session: h.session, connectivity: h.network)
        let model = AdminApprovalsViewModel(service: service, session: h.session)
        h.network.update(isConnected: false)
        await model.load()
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        h.network.update(isConnected: true)
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testAnOldAdminListCannotReturnAfterTheAccountChanges() async throws {
        let h = try await roleHarness()
        let model = AdminRolesViewModel(service: AccountService(api: h.api, session: h.session,
            connectivity: h.network), session: h.session)
        let started = expectation(description: "users")
        var continuation: CheckedContinuation<Data, Error>?
        h.api.users = {
            try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
        }
        let load = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        h.session.signOut()
        model.reset()
        continuation?.resume(returning: Data("{\"users\":[{\"id\":\"\(UUID())\",\"displayName\":\"Old account\",\"role\":\"admin\"}]}".utf8))
        await load.value
        XCTAssertTrue(model.users.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testDetailLoadsItsFileAndCanPrepareAReportWithoutCallingTheServer() async throws {
        let h = try await Harness.make()
        let menu = h.menu
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files = FileStore(cachesDirectory: directory, supportDirectory: directory)
        files.setSession(userID: h.auth.profile.id, generation: h.session.generation)
        let detail = MenuDetail(menu: menu, status: .active, currentVersion: 1, reports: [], serverNow: .now)
        try await files.save(detail, name: "detail-\(menu.id.uuidString)", folder: .caches,
                             userId: h.auth.profile.id, generation: h.session.generation)
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        let saved = SavedMenusViewModel(session: h.session, events: events, clock: h.clock)
        let model = MenuDetailViewModel(menu: menu,
            service: MenuDetailService(api: h.api, session: h.session, files: files, clock: h.clock),
            session: h.session, events: events, saved: saved, connectivity: h.connectivity, clock: h.clock)
        h.connectivity.update(isConnected: false)
        let canReport = await model.canReport()
        XCTAssertEqual(model.detail?.menu.id, menu.id)
        XCTAssertEqual(model.loadError?.code, "OFFLINE")
        XCTAssertTrue(canReport)
        XCTAssertFalse(model.isLoading)
    }

    private func roleHarness(role: String = "admin") async throws -> (api: ScreenAPI, session: SessionStore,
                                               network: ConnectivityService, performance: PerformanceViewModel) {
        let api = ScreenAPI(), auth = FakeAuth()
        api.role = role
        auth.profile = Profile(id: api.userID, displayName: "Fixture", role: role)
        let session = SessionStore(auth: auth, api: api)
        try await session.signIn(email: "fixture@example.invalid", password: "fixture")
        let network = ConnectivityService(monitorNetwork: false)
        let events = EventService(api: api, session: session, connectivity: network, clock: ServerClock())
        let performance = PerformanceViewModel(api: api, session: session, events: events, connectivity: network)
        return (api, session, network, performance)
    }

    private func assertOffline(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected OFFLINE") }
        catch let error as APIFailure { XCTAssertEqual(error.code, "OFFLINE") }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    private var configuration: AppConfiguration { AppConfiguration(supabaseURL: "https://example.invalid", publishableKey: "fixture") }
    private func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScreenConnectivityProtocol.self]
        return URLSession(configuration: config)
    }
}

private struct Ping: Decodable { let status: String }

private final class ScreenConnectivityProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "failure" || path == "cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(path == "failure" ? .notConnectedToInternet : .cancelled))
            return
        }
        let status = path == "server-error" ? 503 : (path == "health" && request.value(forHTTPHeaderField: "Authorization") != nil ? 401 : 200)
        let body = status == 503 ? "{\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"Temporary\"}}" : "{\"status\":\"ok\"}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
private final class ScreenAPI: APIRequesting {
    let userID = UUID()
    var paths: [String] = []
    var dashboard: (() async throws -> Data)?
    var users: (() async throws -> Data)?
    var role = "admin"
    var accountUnavailable = false
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        paths.append(path)
        if accountUnavailable && (path == "me" || path == "establishments/mine") { throw APIFailure.offline }
        let data: Data
        switch path {
        case "me": data = Data("{\"id\":\"\(userID)\",\"displayName\":\"Fixture\",\"role\":\"\(role)\",\"establishments\":[]}".utf8)
        case "establishments/mine": data = Data("{\"establishments\":[]}".utf8)
        case "admin/dashboard": data = try await dashboard?() ?? dashboardData()
        case "admin/users": data = try await users?() ?? Data("{\"users\":[]}".utf8)
        case "admin/memberships": data = Data("{\"memberships\":[]}".utf8)
        case "menus/mine": data = Data("{\"menus\":[]}".utf8)
        default: throw APIFailure.unexpected
        }
        return try UniEatDates.decoder().decode(Response.self, from: data)
    }
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
        query: [URLQueryItem], body: Body?) async throws -> Response {
        paths.append(path)
        throw APIFailure.unexpected
    }
}

private func dashboardData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "periodDays": 7, "generatedAt": "2026-10-30T12:00:00Z", "platform": "ios",
        "bq03": ["feedRequests": 1, "successfulRequests": 1, "failedRequests": 0,
                 "zeroResultRequests": 0, "contextualRequests": 0, "averageResults": 1],
        "bq04": ["detailRequests": 1, "activeShown": 1, "expiringShown": 0, "expiredShown": 0,
                 "closedShown": 0, "pendingNoticesShown": 0, "confirmedNoticesShown": 0],
        "engagement": ["periodDays": 7, "impressions": 1, "detailOpens": 1, "selections": 0,
                       "reportedArrivals": 0, "savedMenus": 0, "locationOpens": 0, "reports": 0],
    ])
}
