import Combine
import Foundation
import UniEatCore

/// copia de un reporte pendiente con solo id y body, que si son Sendable
/// los modelos de swiftdata no pueden cambiar de hilo, por eso a la red se manda esta copia (igual que el outbox de #31)
struct QueuedReport: Identifiable, Sendable {
    let id: UUID
    let body: ReportBody
}

@MainActor
/// lo que la fachada necesita de la base local, como protocolo para probarlo sin swiftdata
protocol ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws
    func pending(userID: UUID) throws -> [QueuedReport]
    func acknowledge(id: UUID, userID: UUID) throws
}

/// la base de #33 cumple el protocolo con sus mismos metodos
extension LocalDatabase: ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws {
        guard !(try pendingReports(userId: userID)).contains(where: { $0.id == id }) else { return }
        try enqueueReport(userId: userID, menu: menu, kind: kind.rawValue, note: note,
                          waitMinutes: waitMinutes, id: id, observedAt: observedAt)
    }
    /// reportes del usuario convertidos a copias que se pueden mandar a otro hilo
    func pending(userID: UUID) throws -> [QueuedReport] {
        try pendingReports(userId: userID).compactMap { report in
            report.body.map { QueuedReport(id: report.id, body: $0) }
        }
    }
    /// el server acepto el reporte, recien ahi se borra de la base
    func acknowledge(id: UUID, userID: UUID) throws {
        if let report = try pendingReports(userId: userID).first(where: { $0.id == id }) {
            try remove(report)
        }
    }
}

/// patron Facade, la hoja de reportar solo pide submitReport y esta clase coordina
/// quien es el usuario, guardar en swiftdata (#33), mandar al server y confirmar
/// solo se encarga de reportes, no maneja pantallas ni formularios
@MainActor
final class ReportingFacade: FeatureViewModel {
    // reportes guardados esperando, se muestra en perfil
    @Published private(set) var pendingReportCount = 0
    // aviso en perfil si un reporte fallo o espera revision
    @Published private(set) var syncMessage: String?
    private let api: APIRequesting
    private let outbox: ReportOutbox?
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let clock: ServerClock
    // sesion que esta mandando la cola, para no mandarla dos veces
    private var flushingGeneration: UUID?
    // reportes que el server rechazo, id -> motivo, no se reintentan solos
    // se guardan por usuario y se reintentan a mano desde perfil
    private var failures: [String: String] = [:]
    init(api: APIRequesting, outbox: ReportOutbox?, session: SessionStore,
         connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api; self.outbox = outbox; self.session = session
        self.connectivity = connectivity; self.clock = clock
    }
    /// al cambiar de cuenta se cargan los rechazados y el conteo de ese usuario
    func accountChanged() {
        syncMessage = nil
        failures = LocalValues.load([String: String].self, key: failureKey) ?? [:]
        if let reason = failures.values.first { syncMessage = "Un reporte requiere revisión y sigue guardado: \(reason)" }
        updateCount()
    }
    private var failureKey: String { "unieat.report-failures.\(session.profile?.id.uuidString ?? "signed-out")" }
    // vuelve a contar los pendientes del usuario
    private func updateCount() {
        guard let userID = session.profile?.id, let outbox else { pendingReportCount = 0; return }
        do { pendingReportCount = try outbox.pending(userID: userID).count }
        catch { syncMessage = "No se pudieron leer los reportes guardados: \(error.localizedDescription)" }
    }
    /// primero se guarda el reporte y despues se intenta mandar
    /// asi si la app se cierra o se va la red no se pierde, sin red devuelve queued
    /// requestID es el id fijo del reporte, si se reintenta el server no lo cuenta dos veces
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?,
                      requestID: UUID = UUID()) async throws -> String {
        guard let userID = session.profile?.id else { throw AuthFailure.expired }
        guard let outbox else {
            throw APIFailure(code: "LOCAL_STORAGE_ERROR", message: "No se pudo abrir la base local. Tu reporte aún no está guardado; conserva el texto e inténtalo de nuevo.")
        }
        try outbox.enqueue(userID: userID, menu: menu, kind: kind, note: note,
                           waitMinutes: waitMinutes, id: requestID, observedAt: clock.now)
        updateCount()
        guard !connectivity.isOffline,
              let report = try outbox.pending(userID: userID).first(where: { $0.id == requestID }) else { return "queued" }
        return try await deliver(report, userID: userID) ?? "queued"
    }
    /// manda los reportes guardados en paralelo (#31), se llama al volver la red o el server
    /// retryRejected en true vuelve a intentar tambien los rechazados, lo usa perfil
    func flushReports(retryRejected: Bool = false) async {
        guard let userID = session.profile?.id, !connectivity.isOffline, flushingGeneration != session.generation, let outbox else { return }
        let expected = session.generation
        if retryRejected { failures = [:]; LocalValues.save(failures, key: failureKey) }
        flushingGeneration = expected
        defer { if flushingGeneration == expected { flushingGeneration = nil }; updateCount() }
        do {
            var waiting = try outbox.pending(userID: userID)
                .filter { failures[$0.id.uuidString] == nil }.makeIterator()
            let api = api
            let owner = session
            // el TaskGroup de #31 con prioridad utility, una tarea hija por reporte
            // maximo 4 a la vez, cuando termina una se mete la siguiente, para no saturar la red
            await withTaskGroup(of: (UUID, DeliveryOutcome).self) { group in
                for _ in 0..<4 {
                    if let report = waiting.next() {
                        group.addTask(priority: .utility) { (report.id, await Self.send(report, api: api, session: owner, userID: userID, generation: expected)) }
                    }
                }
                var canSchedule = true
                for await (id, outcome) in group {
                    guard session.matches(userID, generation: expected), !Task.isCancelled else {
                        group.cancelAll(); return
                    }
                    do { try apply(outcome, id: id, userID: userID) }
                    catch { syncMessage = "El reporte sigue guardado: \(error.localizedDescription)"; canSchedule = false }
                    if case .retry = outcome { canSchedule = false }
                    if case .cancelled = outcome { group.cancelAll(); return }
                    if canSchedule, let report = waiting.next() {
                        group.addTask(priority: .utility) { (report.id, await Self.send(report, api: api, session: owner, userID: userID, generation: expected)) }
                    }
                }
            }
        } catch is CancellationError { }
        catch { syncMessage = "El reporte sigue guardado: \(error.localizedDescription)" }
    }
    /// como le fue a un reporte: enviado, reintentar despues, rechazado con motivo o cancelado por cambio de sesion
    private enum DeliveryOutcome: Sendable {
        case sent(String), retry, rejected(String), cancelled
    }
    /// manda un reporte y traduce el error a un resultado
    /// solo validacion, permisos, no existe, version vieja o vencido cuentan como rechazo
    /// lo demas (red, 429, 500) es reintentar, antes un error del server lo borraba
    private static func send(_ report: QueuedReport, api: APIRequesting, session: SessionStore,
                             userID: UUID, generation: UUID) async -> DeliveryOutcome {
        do {
            // una tarea hija puede arrancar despues de cerrar sesion, se revisa antes de mandar
            guard session.matches(userID, generation: generation) else { return .cancelled }
            try Task.checkCancellation()
            let response: ReportResponse = try await api.send("POST", "reports", body: report.body)
            return .sent(response.status)
        } catch is CancellationError { return .cancelled }
        catch {
            if ["VALIDATION_ERROR", "FORBIDDEN", "NOT_FOUND", "VERSION_CONFLICT", "GONE"].contains((error as? APIFailure)?.code ?? "") {
                return .rejected(error.localizedDescription)
            }
            return .retry
        }
    }
    /// actualiza la base y el aviso segun el resultado, solo un enviado borra la fila
    private func apply(_ outcome: DeliveryOutcome, id: UUID, userID: UUID) throws {
        switch outcome {
        case .sent:
            try outbox?.acknowledge(id: id, userID: userID)
            failures.removeValue(forKey: id.uuidString)
            syncMessage = nil
        case .rejected(let reason):
            failures[id.uuidString] = reason
            syncMessage = "Un reporte requiere revisión y sigue guardado: \(reason)"
        case .retry:
            syncMessage = "El reporte sigue guardado. Se reintentará al recuperar el servicio."
        case .cancelled: return
        }
        LocalValues.save(failures, key: failureKey)
    }
    /// manda un solo reporte apenas se crea, devuelve el estado del server o nil si queda en cola
    private func deliver(_ report: QueuedReport, userID: UUID) async throws -> String? {
        let expected = session.generation
        let outcome = await Self.send(report, api: api, session: session, userID: userID, generation: expected)
        guard session.matches(userID, generation: expected) else { throw CancellationError() }
        try apply(outcome, id: report.id, userID: userID)
        updateCount()
        switch outcome {
        case .sent(let status): return status
        case .rejected: return "needs_review"
        case .retry: return nil
        case .cancelled: throw CancellationError()
        }
    }
}
