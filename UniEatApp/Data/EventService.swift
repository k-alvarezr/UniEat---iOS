import Combine
import Foundation
import UniEatCore

/// la cola de eventos de analitica sale del AppStore viejo a su propio servicio
/// es la misma logica de antes (eventId del celular, una vez por sesion, tope 500, lotes de 100)
/// lo nuevo es que la cola se guarda por usuario y se revisa la sesion antes de aplicar cada respuesta
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
    var metadataProvider: ((DailyMenu) -> ExperimentEventMetadata?)?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api; self.session = session; self.connectivity = connectivity; self.clock = clock
    }
    /// llave de la cola por usuario, asi los eventos de una cuenta no se mandan con otra
    private var key: String { "unieat.remote.pending-events.\(session.profile?.id.uuidString ?? "signed-out")" }
    /// al cambiar de cuenta: sesion nueva, nada contado y se carga la cola de ese usuario
    func accountChanged() {
        objectWillChange.send()
        sessionID = UUID(); counted = []
        pending = session.profile == nil ? [] : LocalValues.load([RemoteEvent].self, key: key) ?? []
    }
    // llave de una accion sobre un menu, con la version para que un menu editado cuente aparte
    private func eventKey(_ kind: String, _ menu: DailyMenu) -> String { "\(kind):\(menu.id):\(menu.version)" }
    func restartSession() { objectWillChange.send(); sessionID = UUID(); counted = [] }
    func hasCounted(_ kind: String, menu: DailyMenu) -> Bool { counted.contains(eventKey(kind, menu)) }
    /// mete el evento en la cola, ver una tarjeta, elegir o llegar cuentan una sola vez por menu y version
    /// la hora es la del server (clock) y no la del celular
    func track(_ kind: String, menu: DailyMenu) {
        guard session.profile != nil else { return }
        objectWillChange.send()
        let metadata = metadataProvider?(menu)
        var dedupKey = eventKey(kind, menu)
        if kind == "feed_impression" {
            // A cached impression must not consume the later eligible live exposure. Existing
            // engagement SQL still counts distinct session/publication/version, not these rows.
            dedupKey += ":\(metadata?.assignmentId.uuidString ?? "ordinary"):\(metadata?.indicatorAvailable ?? false)"
        }
        if ["feed_impression", "selection", "arrival"].contains(kind), !counted.insert(dedupKey).inserted { return }
        pending.append(RemoteEvent(eventId: UUID(), sessionId: sessionID, publicationId: menu.id,
                                    version: menu.version, kind: kind, occurredAt: clock.now, metadata: metadata))
        if pending.count > 500 { pending.removeFirst(pending.count - 500) }
        LocalValues.save(pending, key: key)
        if !connectivity.isOffline { Task { await flush() } }
    }
    /// manda la cola de a 100, si falla se queda para la proxima
    /// si cambia la sesion en medio se para, para no borrar eventos de otra cuenta
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
