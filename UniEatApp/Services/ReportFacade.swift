import Combine
import Foundation
import UniEatCore

/// copia de un reporte guardado con lo que hace falta para mandarlo, todo Sendable
/// los modelos de swiftdata no pueden cambiar de hilo, por eso a la red se manda esta copia (como en #31)
struct ReportToSend: Identifiable, Sendable {
    let id: UUID
    let body: ReportBody
    let rejectedReason: String?   // si el server ya lo rechazo, nil si sigue esperando
}

/// lo que la fachada necesita de la base local, como protocolo para probarla sin swiftdata
@MainActor
protocol ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws
    func pending(userID: UUID) throws -> [ReportToSend]
    func queued(id: UUID, userID: UUID) throws -> ReportToSend?
    func acknowledge(id: UUID, userID: UUID) throws
    func reject(id: UUID, userID: UUID, reason: String) throws
    func clearRejections(userID: UUID) throws
}

/// la base de #33 cumple el protocolo, cada metodo busca por id en vez de cargar toda la cola
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
            copies.append(ReportToSend(id: report.id, body: body, rejectedReason: report.rejectedReason))
        }
        return copies
    }
    /// la copia de un solo reporte, para mandarlo apenas se crea
    func queued(id: UUID, userID: UUID) throws -> ReportToSend? {
        guard let report = try report(id: id, userId: userID), let body = report.body else { return nil }
        return ReportToSend(id: report.id, body: body, rejectedReason: report.rejectedReason)
    }
    /// el server acepto el reporte, recien ahi se borra de la base
    func acknowledge(id: UUID, userID: UUID) throws {
        guard let report = try report(id: id, userId: userID) else { return }
        try remove(report)
    }
    /// el server lo rechazo, se guarda el motivo en la misma fila para revisarlo desde perfil
    func reject(id: UUID, userID: UUID, reason: String) throws {
        guard let report = try report(id: id, userId: userID) else { return }
        try reject(report, reason: reason)
    }
    func clearRejections(userID: UUID) throws {
        try clearRejections(userId: userID)
    }
}

/// como termino un reporte al crearlo, la hoja de reportar lo usa para el mensaje
enum ReportSubmitResult: Equatable {
    case sent(String)   // el server lo acepto, con su estado: pending, confirmed u observation
    case queued         // quedo guardado, se manda cuando vuelva el servicio
    case needsReview    // el server lo rechazo, sigue guardado para revisarlo desde perfil
}

/// patron Facade: la hoja de reportar solo pide submitReport y esta clase coordina
/// quien es el usuario, guardar en swiftdata (#33), mandar al server en paralelo (#31) y confirmar
/// solo se encarga de reportes, no maneja pantallas ni formularios
@MainActor
final class ReportFacade: FeatureViewModel {
    @Published private(set) var pendingReportCount = 0   // guardados esperando para mandarse
    @Published private(set) var needsReviewCount = 0     // rechazados por el server, esperan que el usuario reintente
    @Published private(set) var syncMessage: String?     // aviso en perfil si algo fallo
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

    /// al cambiar de cuenta se cuentan los reportes de ese usuario y se avisa si hay rechazados
    func accountChanged() {
        syncMessage = nil
        sending = []
        updateCounts()
    }

    // vuelve a contar pendientes y rechazados, si hay rechazados muestra el motivo del primero
    private func updateCounts() {
        guard let userID = session.profile?.id, let outbox else {
            pendingReportCount = 0
            needsReviewCount = 0
            return
        }
        do {
            let all = try outbox.pending(userID: userID)
            let rejected = all.filter { $0.rejectedReason != nil }
            pendingReportCount = all.count - rejected.count
            needsReviewCount = rejected.count
            if syncMessage == nil, let reason = rejected.first?.rejectedReason {
                syncMessage = "Un reporte requiere revisión y sigue guardado: \(reason)"
            }
        } catch {
            syncMessage = "No se pudieron leer los reportes guardados: \(error.localizedDescription)"
        }
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

    /// manda los reportes guardados en paralelo (#31), se llama al volver la red o el server
    /// retryRejected en true vuelve a intentar tambien los rechazados, lo usa el boton de perfil
    func sendPendingReports(retryRejected: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        guard !connectivity.isOffline, sendingGeneration != session.generation, let outbox else { return }
        let expected = session.generation
        sendingGeneration = expected
        defer {
            if sendingGeneration == expected { sendingGeneration = nil }
            updateCounts()
        }
        do {
            if retryRejected {
                try outbox.clearRejections(userID: userID)
                syncMessage = nil
            }
            // 1. lo que hay que mandar: ni rechazados ni los que ya van en camino
            var reports: [ReportToSend] = []
            for report in try outbox.pending(userID: userID) where report.rejectedReason == nil && !sending.contains(report.id) {
                reports.append(report)
                sending.insert(report.id)
            }
            defer {
                for report in reports { sending.remove(report.id) }
            }
            // 2. el TaskGroup de #31 con prioridad utility, una tarea hija por reporte
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
                        syncMessage = "El reporte sigue guardado: \(error.localizedDescription)"
                        canSchedule = false
                    }
                    // con el server caido no se siguen mandando, se intenta en la proxima
                    if case .retry = outcome { canSchedule = false }
                    guard canSchedule, let report = waiting.next() else { continue }
                    group.addTask(priority: .utility) {
                        (report.id, await Self.send(report, api: api, session: owner, userID: userID, generation: expected))
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            syncMessage = "El reporte sigue guardado: \(error.localizedDescription)"
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

    /// actualiza la base y el aviso segun el resultado, solo un enviado borra la fila
    private func apply(_ outcome: DeliveryOutcome, id: UUID, userID: UUID) throws {
        switch outcome {
        case .sent:
            try outbox?.acknowledge(id: id, userID: userID)
            syncMessage = nil
        case .rejected(let reason):
            try outbox?.reject(id: id, userID: userID, reason: reason)
            syncMessage = "Un reporte requiere revisión y sigue guardado: \(reason)"
        case .retry:
            syncMessage = "El reporte sigue guardado. Se reintentará al recuperar el servicio."
        case .cancelled:
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
        case .rejected: return .needsReview
        case .retry: return .queued
        case .cancelled: throw CancellationError()
        }
    }
}
