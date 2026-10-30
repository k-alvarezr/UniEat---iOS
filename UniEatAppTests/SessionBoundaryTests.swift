import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class SessionBoundaryTests: XCTestCase {
    func testOldSignOutCannotForgetTheAccountThatSignedInDuringAFlush() async throws {
        let h = try await Harness.make(), oldUser = h.auth.profile.id
        h.connectivity.update(isConnected: false)
        _ = try await h.reports.submitReport(for: h.menu, kind: .price, note: "", waitMinutes: nil)
        h.connectivity.update(isConnected: true)
        let started = expectation(description: "envío suspendido")
        var pending: CheckedContinuation<Void, Never>?
        h.api.onReportAsync = { await withCheckedContinuation { pending = $0; started.fulfill() } }
        var forgotten: [UUID] = []
        h.session.onForget = { userID, _ in forgotten.append(userID) }
        let events = EventService(api: h.api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        let saved = SavedMenusViewModel(session: h.session, events: events, clock: h.clock)
        let profile = ProfileViewModel(session: h.session, saved: saved, reports: h.reports)
        let logout = Task { await profile.signOut() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(profile.isSigningOut)
        h.session.signOut(message: "La sesión venció")
        h.auth.profile = Profile(displayName: "Otra cuenta", role: "student")
        h.api.userID = h.auth.profile.id
        try await h.session.signIn(email: "other@example.invalid", password: "test")
        pending?.resume()
        await logout.value
        XCTAssertEqual(h.session.profile?.id, h.auth.profile.id)
        XCTAssertTrue(forgotten.isEmpty)
        XCTAssertEqual(try h.database.pending(userID: oldUser).count, 1)
        XCTAssertFalse(profile.isSigningOut)
    }

    func testManualCleanupIsAwaitedAndItsFailureIsVisible() async throws {
        let h = try await Harness.make(), owner = h.auth.profile.id, generation = h.session.generation
        let started = expectation(description: "limpieza en curso")
        var pending: CheckedContinuation<Void, Error>?
        h.session.onForget = { userID, departingGeneration in
            XCTAssertEqual(userID, owner); XCTAssertEqual(departingGeneration, generation)
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        let logout = Task { await h.session.signOutAndForget() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(h.session.isForgetting)
        XCTAssertNil(h.session.profile)
        do {
            try await h.session.signIn(email: "other@example.invalid", password: "test")
            XCTFail("El login espera a que termine la limpieza de la cuenta anterior")
        } catch let failure as APIFailure { XCTAssertEqual(failure.code, "LOCAL_STORAGE_BUSY") }
        pending?.resume(throwing: CocoaError(.fileWriteNoPermission))
        await logout.value
        XCTAssertFalse(h.session.isForgetting)
        XCTAssertTrue(h.session.authMessage?.contains("no se pudieron limpiar") == true)
    }

    func testActorCleanupPreservesBookmarksAndRejectsWritesFromTheForgottenSession() async throws {
        let h = try await Harness.make(), owner = h.auth.profile.id, generation = h.session.generation
        let content = LocalContentService(container: h.database.container)
        content.setSession(userID: owner, generation: generation)
        let snapshot = CachedFeedSnapshot(userId: owner, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: .now, menus: [h.menu]))
        try await content.saveFeed(snapshot, generation: generation)
        _ = try await content.toggle(h.menu, userID: owner, savedAt: .now)
        try h.database.enqueueReport(userId: owner, menu: h.menu, kind: "price", note: "", waitMinutes: nil)
        try await content.forget(userID: owner, generation: generation)
        let copy = try await content.feed(userID: owner, filters: FeedFilters())
        let bookmarks = try await content.savedMenus(userID: owner)
        XCTAssertNil(copy)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertTrue(try h.database.pendingReports(userId: owner).isEmpty)
        do {
            try await content.saveFeed(snapshot, generation: generation)
            XCTFail("Una escritura vieja no puede recrear la copia eliminada")
        } catch is CancellationError { }
        let newGeneration = UUID()
        content.setSession(userID: owner, generation: newGeneration)
        try await content.saveFeed(snapshot, generation: newGeneration)
        let restored = try await content.feed(userID: owner, filters: FeedFilters())
        XCTAssertNotNil(restored)
    }

    func testLateSnapshotCannotReplaceANewerSnapshotOfTheSameFilters() async throws {
        let h = try await Harness.make(), content = LocalContentService(container: h.database.container)
        let owner = h.auth.profile.id, date = Date.now
        let newest = CachedFeedSnapshot(userId: owner, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: date, menus: [makeMenu(title: "Nueva respuesta")]))
        let older = CachedFeedSnapshot(userId: owner, filters: FeedFilters(),
            response: FeedResponse(fetchedAt: date.addingTimeInterval(-60), menus: [makeMenu(title: "Llegó tarde")]))
        try await content.saveFeed(newest)
        try await content.saveFeed(older)
        let stored = try await content.feed(userID: owner, filters: FeedFilters())
        XCTAssertEqual(stored?.response.menus.first?.title, "Nueva respuesta")
    }
}
