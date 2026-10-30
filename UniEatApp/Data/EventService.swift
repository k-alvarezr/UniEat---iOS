import Combine
import Foundation
import UniEatCore

/// Diagnóstico local acotado; no son eventos pendientes ni se vuelve a enviar un rechazo permanente.
struct RejectedAnalyticsEvent: Codable {
    let event: RemoteEvent
    let reason: String
    let rejectedAt: Date
}

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
    private(set) var rejectedEvents: [RejectedAnalyticsEvent] = []
    private var flushingGeneration: UUID?
    var metadataProvider: ((DailyMenu) -> ExperimentEventMetadata?)?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.clock = clock
    }
    /// llave de la cola por usuario, asi los eventos de una cuenta no se mandan con otra
    private var key: String { Self.pendingKey(session.profile?.id) }
    /// llave de la cola de un usuario, AppStore la usa para borrarla al cerrar sesion
    static func pendingKey(_ userID: UUID?) -> String { "unieat.remote.pending-events.\(userID?.uuidString ?? "signed-out")" }
    static func rejectedKey(_ userID: UUID) -> String { "unieat.remote.rejected-events.\(userID.uuidString)" }
    /// al cambiar de cuenta: sesion nueva, nada contado y se carga la cola de ese usuario
    func accountChanged() {
        objectWillChange.send()
        sessionID = UUID()
        counted = []
        pending = session.profile == nil ? [] : LocalValues.load([RemoteEvent].self, key: key) ?? []
        rejectedEvents = session.profile.map { LocalValues.load([RejectedAnalyticsEvent].self, key: Self.rejectedKey($0.id)) ?? [] } ?? []
    }
    // llave de una accion sobre un menu, con la version para que un menu editado cuente aparte
    private func eventKey(_ kind: String, _ menu: DailyMenu) -> String { "\(kind):\(menu.id):\(menu.version)" }
    /// sesion de eventos nueva sin cambiar de cuenta, se usa al entrar o salir del piloto de la BQ-08
    func restartSession() {
        objectWillChange.send()
        sessionID = UUID()
        counted = []
    }
    func hasCounted(_ kind: String, menu: DailyMenu) -> Bool { counted.contains(eventKey(kind, menu)) }
    /// mete el evento en la cola, ver una tarjeta, elegir o llegar cuentan una sola vez por menu y version
    /// la hora es la del server (clock) y no la del celular
    func track(_ kind: String, menu: DailyMenu) {
        guard session.profile != nil else { return }
        let metadata = metadataProvider?(menu)
        var dedupKey = eventKey(kind, menu)
        if kind == "feed_impression" {
            // piloto BQ-08: una tarjeta vista desde la copia guardada no gasta la vista en vivo que llega despues
            // las metricas siguen contando sesion, publicacion y version distintas, no estas filas
            dedupKey += ":\(metadata?.assignmentId.uuidString ?? "ordinary"):\(metadata?.indicatorAvailable ?? false)"
        }
        if ["feed_impression", "selection", "arrival"].contains(kind) {
            // ya se conto en esta sesion, no se repite ni se avisa a nadie
            guard !counted.contains(dedupKey) else { return }
            // solo elegir y llegar cambian botones en pantalla (wasChosen, hasArrived)
            // ver una tarjeta no, asi hacer scroll en el feed no redibuja el detalle
            if kind != "feed_impression" { objectWillChange.send() }
            counted.insert(dedupKey)
        }
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
                let response: BatchResponse = try await api.send("POST", "events/batch", body: EventBatch(events: batch))
                guard session.matches(userID, generation: expected) else { return }
                let batchIDs = Set(batch.map(\.eventId))
                let rejectedIDs = Set(response.rejected.compactMap(\.eventId))
                // No se borra un lote si la respuesta no identifica coherentemente su resultado.
                guard response.accepted >= 0, response.duplicates >= 0,
                      response.accepted + response.duplicates + response.rejected.count == batch.count,
                      rejectedIDs.count == response.rejected.count,
                      rejectedIDs.isSubset(of: batchIDs) else { return }
                let permanent = response.rejected.filter { Self.permanentReasons.contains($0.reason) }
                let permanentIDs = Set(permanent.compactMap(\.eventId))
                for rejection in permanent {
                    if let event = batch.first(where: { $0.eventId == rejection.eventId }) {
                        rejectedEvents.append(RejectedAnalyticsEvent(event: event, reason: rejection.reason, rejectedAt: clock.now))
                    }
                }
                if rejectedEvents.count > 100 { rejectedEvents.removeFirst(rejectedEvents.count - 100) }
                LocalValues.save(rejectedEvents, key: Self.rejectedKey(userID))
                // Lo aceptado/duplicado se confirma. Un rechazo permanente queda diagnosticado;
                // uno desconocido conserva el evento para no perder datos con contratos futuros.
                let acknowledged = batchIDs.subtracting(rejectedIDs).union(permanentIDs)
                pending.removeAll { acknowledged.contains($0.eventId) }
                LocalValues.save(pending, key: key)
                if permanent.count != response.rejected.count { return }
            } catch { return }
        }
    }

    private static let permanentReasons: Set<String> = [
        "INVALID_EVENT_ID", "INVALID_SESSION_ID", "INVALID_PUBLICATION_ID", "INVALID_VERSION",
        "UNSUPPORTED_KIND", "INVALID_OCCURRED_AT", "OCCURRED_AT_OUT_OF_WINDOW",
        "UNKNOWN_VERSION", "INVALID_EXPERIMENT_ASSIGNMENT"
    ]
}
