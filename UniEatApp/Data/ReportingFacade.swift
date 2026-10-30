import Combine
import Foundation
import UniEatCore

/// A value snapshot keeps SwiftData objects out of in-flight network operations.
struct QueuedReport: Identifiable {
    let id: UUID
    let body: ReportBody
}

@MainActor
protocol ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws
    func pending(userID: UUID) throws -> [QueuedReport]
    func acknowledge(id: UUID, userID: UUID) throws
}

extension LocalDatabase: ReportOutbox {
    func enqueue(userID: UUID, menu: DailyMenu, kind: ReportKind, note: String,
                 waitMinutes: Int?, id: UUID, observedAt: Date) throws {
        guard !(try pendingReports(userId: userID)).contains(where: { $0.id == id }) else { return }
        try enqueueReport(userId: userID, menu: menu, kind: kind.rawValue, note: note,
                          waitMinutes: waitMinutes, id: id, observedAt: observedAt)
    }
    func pending(userID: UUID) throws -> [QueuedReport] {
        try pendingReports(userId: userID).compactMap { report in
            report.body.map { QueuedReport(id: report.id, body: $0) }
        }
    }
    func acknowledge(id: UUID, userID: UUID) throws {
        if let report = try pendingReports(userId: userID).first(where: { $0.id == id }) {
            try remove(report)
        }
    }
}

/// Facade: a screen requests an operation; this coordinates identity, persistence and transport.
/// It owns no navigation, form fields, ranking, or unrelated feature state.
@MainActor
final class ReportingFacade: FeatureViewModel {
    @Published private(set) var pendingReportCount = 0
    @Published private(set) var syncMessage: String?
    private let api: APIRequesting
    private let outbox: ReportOutbox?
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let clock: ServerClock
    private var isFlushing = false
    private var failures: [String: String] = [:]
    init(api: APIRequesting, outbox: ReportOutbox?, session: SessionStore,
         connectivity: ConnectivityService, clock: ServerClock) {
        self.api = api; self.outbox = outbox; self.session = session
        self.connectivity = connectivity; self.clock = clock
    }
    func accountChanged() {
        syncMessage = nil
        failures = LocalValues.load([String: String].self, key: failureKey) ?? [:]
        updateCount()
    }
    private var failureKey: String { "unieat.report-failures.\(session.profile?.id.uuidString ?? "signed-out")" }
    private func updateCount() {
        guard let userID = session.profile?.id, let outbox else { pendingReportCount = 0; return }
        do { pendingReportCount = try outbox.pending(userID: userID).count }
        catch { syncMessage = "No se pudieron leer los reportes guardados: \(error.localizedDescription)" }
    }
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
    func flushReports(retryRejected: Bool = false) async {
        guard let userID = session.profile?.id, !connectivity.isOffline, !isFlushing, let outbox else { return }
        let expected = session.generation
        if retryRejected { failures = [:]; LocalValues.save(failures, key: failureKey) }
        isFlushing = true
        defer { isFlushing = false; updateCount() }
        do {
            for report in try outbox.pending(userID: userID) {
                guard session.matches(userID, generation: expected), !connectivity.isOffline else { return }
                if failures[report.id.uuidString] != nil { continue }
                if try await deliver(report, userID: userID) == nil { return }
            }
        } catch is CancellationError { }
        catch { syncMessage = "El reporte sigue guardado: \(error.localizedDescription)" }
    }
    private func deliver(_ report: QueuedReport, userID: UUID) async throws -> String? {
        let expected = session.generation
        do {
            let response: ReportResponse = try await api.send("POST", "reports", body: report.body)
            guard session.matches(userID, generation: expected) else { throw CancellationError() }
            // Only a successful acknowledgement permits deleting the durable pending row.
            try outbox?.acknowledge(id: report.id, userID: userID)
            failures.removeValue(forKey: report.id.uuidString)
            LocalValues.save(failures, key: failureKey)
            syncMessage = nil; updateCount()
            return response.status
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard session.matches(userID, generation: expected) else { throw CancellationError() }
            let failure = error as? APIFailure
            let permanent = ["VALIDATION_ERROR", "FORBIDDEN", "NOT_FOUND", "VERSION_CONFLICT", "GONE"]
            if permanent.contains(failure?.code ?? "") {
                failures[report.id.uuidString] = error.localizedDescription
                LocalValues.save(failures, key: failureKey)
                syncMessage = "Un reporte requiere revisión y sigue guardado: \(error.localizedDescription)"
            } else {
                syncMessage = "El reporte sigue guardado. Se reintentará al recuperar el servicio."
            }
            updateCount()
            return nil
        }
    }
}
