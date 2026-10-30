import Combine
import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class DraftEventDurabilityTests: XCTestCase {
    func testRevokedFileSessionCannotRecreateForgottenFilesAndANewSessionCanSave() async throws {
        let files = makeFiles(), owner = UUID(), old = UUID(), next = UUID()
        try await files.save("Antes", name: "draft", folder: .support, userId: owner, generation: old)
        try await files.removeAll(userId: owner, invalidating: old)
        do {
            try await files.save("Tarde", name: "draft", folder: .support, userId: owner, generation: old)
            XCTFail("Una escritura de la sesión retirada no debe recrear archivos")
        } catch is CancellationError { }
        let forgotten = try await files.load(String.self, name: "draft", folder: .support, userId: owner)
        XCTAssertNil(forgotten)
        try await files.save("Nueva sesión", name: "draft", folder: .support, userId: owner, generation: next)
        let current = try await files.load(String.self, name: "draft", folder: .support, userId: owner)
        XCTAssertEqual(current, "Nueva sesión")
    }

    func testAnOlderDraftRevisionCannotReplaceANewerWrite() async throws {
        let files = makeFiles(), owner = UUID(), generation = UUID()
        try await files.save("Último", name: "draft", folder: .support, userId: owner, generation: generation, revision: 2)
        do {
            try await files.save("Anterior", name: "draft", folder: .support, userId: owner, generation: generation, revision: 1)
            XCTFail("La llegada tardía no debe sobrescribir una revisión posterior")
        } catch is CancellationError { }
        let stored = try await files.load(String.self, name: "draft", folder: .support, userId: owner)
        XCTAssertEqual(stored, "Último")
    }

    func testForgettingAnAccountAlsoBlocksWritesFromItsEarlierExpiredGeneration() async throws {
        let files = makeFiles(), owner = UUID(), first = UUID(), second = UUID(), third = UUID()
        files.setSession(userID: owner, generation: first)
        files.setSession(userID: nil, generation: UUID())
        // Vencer automáticamente conserva la última generación y su trabajo pendiente.
        try await files.save("Pendiente A1", name: "draft", folder: .support, userId: owner, generation: first)
        files.setSession(userID: owner, generation: second)
        files.invalidate(userID: owner)
        try await files.removeAll(userId: owner, invalidating: second)
        for old in [first, second] {
            do {
                try await files.save("Escritura tardía", name: "draft", folder: .support, userId: owner, generation: old)
                XCTFail("La limpieza cubre todas las generaciones antiguas de la cuenta")
            } catch is CancellationError { }
        }
        let forgotten = try await files.load(String.self, name: "draft", folder: .support, userId: owner)
        XCTAssertNil(forgotten)
        files.setSession(userID: owner, generation: third)
        try await files.save("Nueva A3", name: "draft", folder: .support, userId: owner, generation: third)
        do {
            try await files.remove(name: "draft", folder: .support, userId: owner, generation: first)
            XCTFail("A1 tampoco puede borrar el trabajo de A3")
        } catch is CancellationError { }
        let current = try await files.load(String.self, name: "draft", folder: .support, userId: owner)
        XCTAssertEqual(current, "Nueva A3")
    }

    func testDebouncedDraftSavesLatestFieldsAndLifecycleFlushDoesNotWaitForTheTimer() async throws {
        let h = try await Harness.make(), files = makeFiles()
        let model = makePublication(h, files: files, delay: .milliseconds(10))
        model.dishes[0].name = "Sopa"; model.dishes[0].priceText = "12000"
        model.title = "Primero"; model.scheduleDraftSave()
        model.title = "Último"; model.scheduleDraftSave()
        let saved = expectation(description: "guardado con debounce")
        let observation = model.$draftSavedAt.compactMap { $0 }.prefix(1).sink { _ in saved.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [saved], timeout: 3)
        var copy = try await files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: h.auth.profile.id)
        XCTAssertEqual(copy?.title, "Último")
        model.title = "Al pasar a segundo plano"
        model.scheduleDraftSave()
        await model.flushDraft()
        copy = try await files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: h.auth.profile.id)
        XCTAssertEqual(copy?.title, "Al pasar a segundo plano")
        XCTAssertNil(model.draftError)
    }

    func testDraftWriteFailureIsVisibleAndDoesNotDiscardTheForm() async throws {
        let h = try await Harness.make(), directory = temporaryDirectory()
        let blocked = directory.appending(path: "not-a-directory")
        try Data("archivo".utf8).write(to: blocked)
        let files = FileStore(cachesDirectory: directory, supportDirectory: blocked)
        let model = makePublication(h, files: files)
        model.title = "Conservar este formulario"
        model.dishes[0].name = "Arroz"
        await model.flushDraft()
        XCTAssertNotNil(model.draftError)
        XCTAssertNil(model.draftSavedAt)
        XCTAssertEqual(model.title, "Conservar este formulario")
        XCTAssertEqual(model.dishes[0].name, "Arroz")
    }

    func testAnOldPublicationSessionCannotClearTheNextSessionsDraft() async throws {
        let h = try await Harness.make(), files = makeFiles()
        let service = PublishService(api: h.api, session: h.session, files: files)
        let owner = h.auth.profile.id, old = h.session.generation
        h.session.signOut()
        try await h.session.signIn(email: "test@example.invalid", password: "test")
        var draft = makePublication(h, files: files).currentDraft
        draft.title = "Borrador de la sesión nueva"
        try await service.saveDraft(draft, userID: owner, generation: h.session.generation)
        do {
            try await service.clearDraft(userID: owner, generation: old)
            XCTFail("Una publicación vieja no borra el borrador de la siguiente sesión")
        } catch is CancellationError { }
        let stored = try await files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: owner)
        XCTAssertEqual(stored?.title, draft.title)
    }

    func testPartialEventAcknowledgementSeparatesPermanentRejectionsWithoutRetryingThem() async throws {
        let h = try await Harness.make(), api = DurabilityEventAPI(), user = h.auth.profile.id
        let rows = (0..<3).map { _ in event(menu: h.menu) }
        let key = EventService.pendingKey(user), rejectedKey = EventService.rejectedKey(user)
        defer { UserDefaultsStore.remove(key: key); UserDefaultsStore.remove(key: rejectedKey) }
        UserDefaultsStore.save(rows, key: key)
        api.reply = { _ in try JSONSerialization.data(withJSONObject: ["accepted": 1, "duplicates": 1,
            "rejected": [["eventId": rows[2].eventId.uuidString, "reason": "UNKNOWN_VERSION"]]]) }
        let events = EventService(api: api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        events.accountChanged(); await events.sendPending(); await events.sendPending()
        XCTAssertEqual(api.calls, 1)
        XCTAssertTrue((UserDefaultsStore.load([RemoteEvent].self, key: key) ?? []).isEmpty)
        XCTAssertEqual(events.rejectedEvents.map(\.event.eventId), [rows[2].eventId])
        XCTAssertEqual(events.rejectedEvents.first?.reason, "UNKNOWN_VERSION")
    }

    func testNetworkAndUnknownEventRejectionsKeepRetryableEventsWithoutALoop() async throws {
        let h = try await Harness.make(), api = DurabilityEventAPI(), user = h.auth.profile.id
        let rows = (0..<2).map { _ in event(menu: h.menu) }, key = EventService.pendingKey(user)
        defer { UserDefaultsStore.remove(key: key); UserDefaultsStore.remove(key: EventService.rejectedKey(user)) }
        UserDefaultsStore.save(rows, key: key)
        let events = EventService(api: api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        events.accountChanged()
        api.failure = .offline
        await events.sendPending()
        XCTAssertEqual(UserDefaultsStore.load([RemoteEvent].self, key: key)?.count, 2)
        api.failure = nil
        api.reply = { _ in try JSONSerialization.data(withJSONObject: ["accepted": 1, "duplicates": 0,
            "rejected": [["eventId": rows[1].eventId.uuidString, "reason": "TEMPORARY_FUTURE_REASON"]]]) }
        await events.sendPending()
        XCTAssertEqual(api.calls, 2)
        XCTAssertEqual(UserDefaultsStore.load([RemoteEvent].self, key: key)?.map(\.eventId), [rows[1].eventId])
        XCTAssertTrue(events.rejectedEvents.isEmpty)
        // Una respuesta incoherente tampoco confirma datos que no sabemos si se registraron.
        api.reply = { _ in Data("{\"accepted\":99,\"duplicates\":0,\"rejected\":[]}".utf8) }
        await events.sendPending()
        XCTAssertEqual(UserDefaultsStore.load([RemoteEvent].self, key: key)?.count, 1)
    }

    func testPermanentEventDiagnosticsAreBoundedAcrossBatches() async throws {
        let h = try await Harness.make(), api = DurabilityEventAPI(), user = h.auth.profile.id
        let rows = (0..<120).map { _ in event(menu: h.menu) }, key = EventService.pendingKey(user)
        defer { UserDefaultsStore.remove(key: key); UserDefaultsStore.remove(key: EventService.rejectedKey(user)) }
        UserDefaultsStore.save(rows, key: key)
        api.reply = { data in
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let sent = body["events"] as! [[String: Any]]
            return try JSONSerialization.data(withJSONObject: ["accepted": 0, "duplicates": 0,
                "rejected": sent.map { ["eventId": $0["eventId"]!, "reason": "UNKNOWN_VERSION"] }])
        }
        let events = EventService(api: api, session: h.session, connectivity: h.connectivity, clock: h.clock)
        events.accountChanged(); await events.sendPending()
        XCTAssertEqual(api.calls, 2)
        XCTAssertEqual(events.rejectedEvents.count, 100)
        XCTAssertEqual(events.rejectedEvents.map(\.event.eventId), Array(rows.suffix(100)).map(\.eventId))
        XCTAssertTrue((UserDefaultsStore.load([RemoteEvent].self, key: key) ?? []).isEmpty)
    }

    private func makePublication(_ h: Harness, files: FileStore, delay: Duration = .seconds(60)) -> PublishViewModel {
        PublishViewModel(service: PublishService(api: h.api, session: h.session, files: files), feed: h.feed,
            session: h.session, connectivity: h.connectivity, clock: h.clock, draftSaveDelay: delay)
    }
    private func event(menu: DailyMenu) -> RemoteEvent {
        RemoteEvent(eventId: UUID(), sessionId: UUID(), publicationId: menu.id, version: menu.version, kind: "detail_open", occurredAt: .now)
    }
    private func makeFiles() -> FileStore {
        let directory = temporaryDirectory()
        return FileStore(cachesDirectory: directory.appending(path: "caches"), supportDirectory: directory.appending(path: "support"))
    }
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

@MainActor
private final class DurabilityEventAPI: APIRequesting {
    var calls = 0
    var failure: APIFailure?
    var reply: ((Data) throws -> Data)?
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response { throw APIFailure.unexpected }
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
        query: [URLQueryItem], body: Body?) async throws -> Response {
        calls += 1
        if let failure { throw failure }
        let data = try UniEatDates.encoder().encode(body)
        return try UniEatDates.decoder().decode(Response.self, from: try reply!(data))
    }
}
