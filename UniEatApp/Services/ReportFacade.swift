import Combine
import Foundation
import UniEatCore

/// copia de un reporte guardado con lo que hace falta para mandarlo, todo Sendable
/// los modelos de swiftdata no pueden cambiar de hilo, por eso a la red se manda esta copia
struct ReportToSend: Identifiable, Sendable {
    let id: UUID
    let body: ReportBody
}

/// lo que la fachada necesita de la base local, como protocolo para probarla sin swiftdata
@MainActor
protocol ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws
    func pending(userID: UUID) throws -> [ReportToSend]
    func queued(id: UUID, userID: UUID) throws -> ReportToSend?
    func acknowledge(id: UUID, userID: UUID) throws
}

/// la base local cumple el protocolo, cada metodo busca por id en vez de cargar toda la cola
extension LocalDatabase: ReportOutbox {
    /// guarda el reporte, si ya existe ese id para el usuario no lo repite (es un reintento)
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws {
        guard try report(id: id, userId: userID) == nil else { return }
        try enqueueReport(userId: userID, menu: menu, kind: kind.rawValue, note: note,
                          waitMinutes: waitMinutes, id: id, observedAt: observedAt)
    }
    /// reportes del usuario convertidos a copias que se pueden mandar a otro hilo
    func pending(userID: UUID) throws -> [ReportToSend] {
        var copies: [ReportToSend] = []
        for report in try pendingReports(userId: userID) {
            guard let body = report.body else { continue }
            copies.append(ReportToSend(id: report.id, body: body))
        }
        return copies
    }
    /// la copia de un solo reporte, para mandarlo apenas se crea
    func queued(id: UUID, userID: UUID) throws -> ReportToSend? {
        guard let report = try report(id: id, userId: userID), let body = report.body else { return nil }
        return ReportToSend(id: report.id, body: body)
    }
    /// el server respondio (lo acepto o lo rechazo para siempre), se borra de la base
    func acknowledge(id: UUID, userID: UUID) throws {
        guard let report = try report(id: id, userId: userID) else { return }
        try remove(report)
    }
}

/// como termino un reporte al crearlo, la hoja de reportar lo usa para el mensaje
enum ReportSubmitResult: Equatable {
    case sent(String)   // el server lo acepto, con su estado: pending, confirmed u observation
    case queued         // quedo guardado, se manda cuando vuelva el servicio
    case rejected(String)   // el server lo rechazo con un error que no se arregla reintentando, se borra de la cola
}

/// patron Facade: la hoja de reportar solo pide submitReport y esta clase coordina
/// quien es el usuario, guardar en swiftdata, mandar al server en paralelo y confirmar
/// solo se encarga de reportes, no maneja pantallas ni formularios
@MainActor
final class ReportFacade: FeatureViewModel {
    @Published private(set) var pendingReportCount = 0   // guardados esperando para mandarse
    private let api: APIRequesting
    private let outbox: ReportOutbox?
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let clock: ServerClock
    private var sendingGeneration: UUID?   // sesion que esta mandando la cola, para no mandarla dos veces
    private var sending: Set<UUID> = []     // reportes que van en camino, asi nadie manda el mismo dos veces
    private static let maxParallel = 4      // envios a la vez, para no saturar la red ni el server

    init(api: APIRequesting, outbox: ReportOutbox?, session: SessionStore,
         connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api
        self.outbox = outbox
        self.session = session
        self.connectivity = connectivity
        self.clock = clock
    }

    /// al cambiar de cuenta se cuentan los reportes de ese usuario
    func accountChanged() {
        sending = []
        updateCounts()
    }

    // vuelve a contar los reportes que esperan en la cola
    private func updateCounts() {
        guard let userID = session.profile?.id, let outbox else {
            pendingReportCount = 0
            return
        }
        pendingReportCount = (try? outbox.pending(userID: userID).count) ?? 0
    }

    /// primero se guarda el reporte y despues se intenta mandar
    /// asi si la app se cierra o se va la red no se pierde
    /// requestID es el id fijo del reporte, si se reintenta el server no lo cuenta dos veces
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?,
                      requestID: UUID = UUID()) async throws -> ReportSubmitResult {
        guard let userID = session.profile?.id else { throw AuthFailure.expired }
        guard let outbox else {
            throw APIFailure(code: "LOCAL_STORAGE_ERROR", message: "No se pudo abrir la base local. Tu reporte aún no está guardado; conserva el texto e inténtalo de nuevo.")
        }
        // 1. guardar
        try outbox.enqueue(userID: userID, menu: menu, kind: kind, note: note,
                           waitMinutes: waitMinutes, id: requestID, observedAt: clock.now)
        updateCounts()
        // 2. sin red queda en cola
        guard !connectivity.isOffline else { return .queued }
        guard let report = try outbox.queued(id: requestID, userID: userID) else { return .queued }
        // 3. mandarlo ya
        return try await deliver(report, userID: userID)
    }

    /// manda los reportes guardados en paralelo, se llama al volver la red o el server
    func sendPendingReports() async {
        guard let userID = session.profile?.id else { return }
        guard !connectivity.isOffline, sendingGeneration != session.generation, let outbox else { return }
        let expected = session.generation
        sendingGeneration = expected
        defer {
            if sendingGeneration == expected { sendingGeneration = nil }
            updateCounts()
        }
        do {
            // 1. lo que hay que mandar: todo lo de la cola menos lo que ya va en camino
            var reports: [ReportToSend] = []
            for report in try outbox.pending(userID: userID) where !sending.contains(report.id) {
                reports.append(report)
                sending.insert(report.id)
            }
            defer {
                for report in reports { sending.remove(report.id) }
            }
            // 2. un TaskGroup con prioridad utility, una tarea hija por reporte
            //    arrancan maxParallel y cuando termina una entra la siguiente
            var waiting = reports.makeIterator()
            let api = api
            let owner = session
            await withTaskGroup(of: (UUID, DeliveryOutcome).self) { group in
                for _ in 0..<Self.maxParallel {
                    guard let report = waiting.next() else { break }
                    group.addTask(priority: .utility) {
                        (report.id, await Self.send(report, api: api, session: owner, userID: userID, generation: expected))
                    }
                }
                // 3. cada resultado se aplica en el hilo principal, swiftdata solo se toca aca
                var canSchedule = true
                for await (id, outcome) in group {
                    // si cerraron sesion se paran todas
                    guard session.matches(userID, generation: expected), !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if case .cancelled = outcome {
                        group.cancelAll()
                        return
                    }
                    do {
                        try apply(outcome, id: id, userID: userID)
                    } catch {
                        canSchedule = false   // si la base fallo no se sigue, el reporte sigue guardado
                    }
                    // con el server caido no se siguen mandando, se intenta en la proxima
                    if case .retry = outcome { canSchedule = false }
                    guard canSchedule, let report = waiting.next() else { continue }
                    group.addTask(priority: .utility) {
                        (report.id, await Self.send(report, api: api, session: owner, userID: userID, generation: expected))
                    }
                }
            }
        } catch {
            // cancelado o la base no se pudo leer: lo guardado se queda y se intenta en la proxima
        }
    }

    /// como le fue a un envio: enviado, reintentar despues, rechazado con motivo o cancelado por cambio de sesion
    private enum DeliveryOutcome: Sendable {
        case sent(String)
        case retry
        case rejected(String)
        case cancelled
    }

    /// manda un reporte y traduce el error a un resultado
    /// solo los errores permanentes cuentan como rechazo, lo demas (red, 429, 500) se reintenta
    private static func send(_ report: ReportToSend, api: APIRequesting, session: SessionStore,
                             userID: UUID, generation: UUID) async -> DeliveryOutcome {
        do {
            // una tarea hija puede arrancar despues de cerrar sesion, se revisa antes de mandar
            guard session.matches(userID, generation: generation) else { return .cancelled }
            try Task.checkCancellation()
            let response: ReportResponse = try await api.send("POST", "reports", body: report.body)
            return .sent(response.status)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as APIFailure where failure.isPermanent {
            return .rejected(failure.localizedDescription)
        } catch {
            return .retry
        }
    }

    /// actualiza la base segun el resultado
    /// enviado o rechazado se borra de la cola (rechazado es un error que no se arregla reintentando),
    /// si toca reintentar o se cancelo se queda guardado
    private func apply(_ outcome: DeliveryOutcome, id: UUID, userID: UUID) throws {
        switch outcome {
        case .sent, .rejected:
            try outbox?.acknowledge(id: id, userID: userID)
        case .retry, .cancelled:
            return
        }
    }

    /// manda un solo reporte apenas se crea
    /// si la cola ya lo esta mandando no se manda otra vez, queda como en cola
    private func deliver(_ report: ReportToSend, userID: UUID) async throws -> ReportSubmitResult {
        guard !sending.contains(report.id) else { return .queued }
        sending.insert(report.id)
        defer { sending.remove(report.id) }

        let expected = session.generation
        let outcome = await Self.send(report, api: api, session: session, userID: userID, generation: expected)
        guard session.matches(userID, generation: expected) else { throw CancellationError() }
        try apply(outcome, id: report.id, userID: userID)
        updateCounts()
        switch outcome {
        case .sent(let status): return .sent(status)
        case .rejected(let reason): return .rejected(reason)
        case .retry: return .queued
        case .cancelled: throw CancellationError()
        }
    }
}
