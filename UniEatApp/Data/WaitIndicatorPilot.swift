import Combine
import Foundation
import UniEatCore

struct PilotAssignment: Decodable, Sendable {
    let assignmentId: UUID
    let sessionId: UUID
    let experimentKey: String
    let variant: String
    let assignedAt: Date
    let serverNow: Date
}

struct ExperimentEventMetadata: Codable, Equatable, Sendable {
    let assignmentId: UUID
    let experimentKey: String
    let variant: String
    let indicatorAvailable: Bool
    let indicatorShown: Bool
    let source: String
}

@MainActor
final class WaitIndicatorPilot: FeatureViewModel {
    @Published private(set) var isEnabled = false
    @Published private(set) var assignment: PilotAssignment?
    @Published private(set) var message: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let clock: ServerClock
    private var assigning: Task<PilotAssignment, Error>?
    private var requestID = UUID()
    var onParticipationChanged: (() -> Void)?
    init(api: APIRequesting, session: SessionStore, clock: ServerClock) {
        self.api = api; self.session = session; self.clock = clock
        super.init(); observe(session)
    }
    var isStudent: Bool { session.profile?.role == "student" }
    var showsWaitIndicator: Bool { !isEnabled || !isStudent || assignment?.variant != "control" }
    private var key: String { "unieat.wait-pilot.\(session.profile?.id.uuidString ?? "signed-out")" }
    func accountChanged() {
        assigning?.cancel(); assigning = nil; requestID = UUID(); assignment = nil; message = nil
        isEnabled = session.profile != nil && UserDefaults.standard.bool(forKey: key)
    }
    func setEnabled(_ value: Bool) {
        guard isStudent, value != isEnabled else { return }
        isEnabled = value; assignment = nil; message = nil; assigning?.cancel(); assigning = nil; requestID = UUID()
        UserDefaults.standard.set(value, forKey: key)
        onParticipationChanged?()
    }
    func prepare(sessionID: UUID) async {
        guard isEnabled, isStudent, assignment?.sessionId != sessionID, let userID = session.profile?.id else { return }
        let generation = session.generation
        struct Request: Encodable { let sessionId: UUID; let participating = true }
        let id: UUID
        let task: Task<PilotAssignment, Error>
        if let pending = assigning { task = pending; id = requestID }
        else {
            id = UUID(); requestID = id
            task = Task<PilotAssignment, Error> { try await api.send("POST", "experiments/bq08/assignment", body: Request(sessionId: sessionID)) }
            assigning = task
        }
        defer { if requestID == id { assigning = nil } }
        do {
            let value = try await task.value
            guard session.matches(userID, generation: generation), requestID == id, isEnabled, !Task.isCancelled,
                  value.sessionId == sessionID, value.experimentKey == "bq08-wait-v1",
                  ["control", "treatment"].contains(value.variant) else { return }
            assignment = value; clock.synchronize(value.serverNow); message = nil
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            assignment = nil; message = "El piloto no está disponible ahora. Puedes seguir usando el indicador habitual."
        }
    }
    func metadata(menu: DailyMenu, sessionID: UUID, live: Bool) -> ExperimentEventMetadata? {
        guard isEnabled, isStudent, live, let assignment, assignment.sessionId == sessionID else { return nil }
        let available = menu.hasWaitEvidence(at: clock.now)
        return ExperimentEventMetadata(assignmentId: assignment.assignmentId, experimentKey: assignment.experimentKey,
            variant: assignment.variant, indicatorAvailable: available,
            indicatorShown: available && showsWaitIndicator, source: "live")
    }
    func explanation(_ text: String) -> String {
        guard !showsWaitIndicator else { return text }
        return text.components(separatedBy: " · ").filter { !$0.localizedCaseInsensitiveContains("fila") }.joined(separator: " · ")
    }
}
