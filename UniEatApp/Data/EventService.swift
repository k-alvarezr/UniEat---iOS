import Combine
import Foundation
import UniEatCore

@MainActor
final class EventService: ObservableObject {
    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let clock: ServerClock
    private(set) var sessionID = UUID()
    private var counted: Set<String> = []
    private var pending: [RemoteEvent] = []
    private var flushingGeneration: UUID?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api; self.session = session; self.connectivity = connectivity; self.clock = clock
    }
    private var key: String { "unieat.remote.pending-events.\(session.profile?.id.uuidString ?? "signed-out")" }
    func accountChanged() {
        objectWillChange.send()
        sessionID = UUID(); counted = []
        pending = session.profile == nil ? [] : LocalValues.load([RemoteEvent].self, key: key) ?? []
    }
    private func eventKey(_ kind: String, _ menu: DailyMenu) -> String { "\(kind):\(menu.id):\(menu.version)" }
    func hasCounted(_ kind: String, menu: DailyMenu) -> Bool { counted.contains(eventKey(kind, menu)) }
    func track(_ kind: String, menu: DailyMenu) {
        guard session.profile != nil else { return }
        objectWillChange.send()
        if ["feed_impression", "selection", "arrival"].contains(kind), !counted.insert(eventKey(kind, menu)).inserted { return }
        pending.append(RemoteEvent(eventId: UUID(), sessionId: sessionID, publicationId: menu.id,
                                    version: menu.version, kind: kind, occurredAt: clock.now))
        if pending.count > 500 { pending.removeFirst(pending.count - 500) }
        LocalValues.save(pending, key: key)
        if !connectivity.isOffline { Task { await flush() } }
    }
    func flush() async {
        guard let userID = session.profile?.id, !connectivity.isOffline, flushingGeneration != session.generation else { return }
        let expected = session.generation
        flushingGeneration = expected
        defer { if flushingGeneration == expected { flushingGeneration = nil } }
        while !pending.isEmpty && !connectivity.isOffline && session.matches(userID, generation: expected) {
            let batch = Array(pending.prefix(100))
            do {
                let _: BatchResponse = try await api.send("POST", "events/batch", body: EventBatch(events: batch))
                guard session.matches(userID, generation: expected) else { return }
                pending.removeAll { batch.contains($0) }
                LocalValues.save(pending, key: key)
            } catch { return }
        }
    }
}
