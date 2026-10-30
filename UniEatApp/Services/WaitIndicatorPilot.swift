import Combine
import Foundation
import UniEatCore

/// variante que el server le asigno a esta sesion en el piloto de la BQ-08
struct PilotAssignment: Decodable, Sendable {
    let assignmentId: UUID
    let sessionId: UUID
    let experimentKey: String
    let variant: String   // control (sin indicador de fila) o treatment (con indicador)
    let assignedAt: Date
    let serverNow: Date
}

/// datos del piloto que van pegados a cada evento, para comparar los dos grupos en el tablero
struct ExperimentEventMetadata: Codable, Equatable, Sendable {
    let assignmentId: UUID
    let experimentKey: String
    let variant: String
    let indicatorAvailable: Bool   // habia datos suficientes de fila para ese menu
    let indicatorShown: Bool       // y se le mostro al estudiante
    let source: String
}

/// piloto de la BQ-08 (Kevin, #30): el estudiante que se anota desde perfil queda en control o treatment
/// en control no ve el indicador de fila, asi se compara si el indicador cambia lo que eligen
@MainActor
final class WaitIndicatorPilot: FeatureViewModel {
    @Published private(set) var isEnabled = false               // el estudiante se anoto al piloto
    @Published private(set) var assignment: PilotAssignment?    // variante de esta sesion
    @Published private(set) var message: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let clock: ServerClock
    private var assigning: Task<PilotAssignment, Error>?   // pedido de variante en camino, se reutiliza
    private var requestID = UUID()
    var onParticipationChanged: (() -> Void)?             // AppContainer reinicia la sesion de eventos y el feed
    init(api: APIRequesting, session: SessionStore, clock: ServerClock) {
        self.api = api
        self.session = session
        self.clock = clock
        super.init()
        observe(session)
    }
    var isStudent: Bool { session.profile?.role == "student" }
    /// se muestra el indicador si no participa, si no es estudiante o si le toco treatment
    var showsWaitIndicator: Bool { !isEnabled || !isStudent || assignment?.variant != "control" }
    private var key: String { "unieat.wait-pilot.\(session.profile?.id.uuidString ?? "signed-out")" }
    /// al cambiar de cuenta se olvida la variante y se lee si esta cuenta estaba anotada
    func accountChanged() {
        assigning?.cancel()
        assigning = nil
        requestID = UUID()
        assignment = nil
        message = nil
        isEnabled = session.profile != nil && UserDefaults.standard.bool(forKey: key)
    }
    /// anotarse o salirse del piloto desde perfil, solo estudiantes
    func setEnabled(_ value: Bool) {
        guard isStudent, value != isEnabled else { return }
        isEnabled = value
        assignment = nil
        message = nil
        assigning?.cancel()
        assigning = nil
        requestID = UUID()
        UserDefaults.standard.set(value, forKey: key)
        onParticipationChanged?()
    }
    /// pide al server la variante de esta sesion antes de cargar el feed
    /// si ya hay un pedido en camino se espera ese en vez de mandar otro
    func prepare(sessionID: UUID) async {
        guard isEnabled, isStudent, assignment?.sessionId != sessionID, let userID = session.profile?.id else { return }
        let generation = session.generation
        struct Request: Encodable {
            let sessionId: UUID
            let participating = true
        }
        let id: UUID
        let task: Task<PilotAssignment, Error>
        if let pending = assigning {
            task = pending
            id = requestID
        } else {
            id = UUID()
            requestID = id
            task = Task<PilotAssignment, Error> { try await api.send("POST", "experiments/bq08/assignment", body: Request(sessionId: sessionID)) }
            assigning = task
        }
        defer { if requestID == id { assigning = nil } }
        do {
            let value = try await task.value
            // se revisa que siga siendo la misma cuenta y que la respuesta sea una variante valida
            guard session.matches(userID, generation: generation), requestID == id, isEnabled, !Task.isCancelled,
                  value.sessionId == sessionID, value.experimentKey == "bq08-wait-v1",
                  ["control", "treatment"].contains(value.variant) else { return }
            assignment = value
            clock.synchronize(value.serverNow)
            message = nil
        } catch is CancellationError {
        } catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            assignment = nil
            message = "El piloto no está disponible ahora. Puedes seguir usando el indicador habitual."
        }
    }
    /// datos del piloto para un evento, solo si participa y lo que ve viene del server (no de la copia)
    func metadata(menu: DailyMenu, sessionID: UUID, live: Bool) -> ExperimentEventMetadata? {
        guard isEnabled, isStudent, live, let assignment, assignment.sessionId == sessionID else { return nil }
        let available = menu.hasWaitEvidence(at: clock.now)
        return ExperimentEventMetadata(assignmentId: assignment.assignmentId, experimentKey: assignment.experimentKey,
            variant: assignment.variant, indicatorAvailable: available,
            indicatorShown: available && showsWaitIndicator, source: "live")
    }
    /// en control se quita de la explicacion del ranking la parte que habla de la fila
    func explanation(_ text: String) -> String {
        guard !showsWaitIndicator else { return text }
        return text.components(separatedBy: " · ").filter { !$0.localizedCaseInsensitiveContains("fila") }.joined(separator: " · ")
    }
}
