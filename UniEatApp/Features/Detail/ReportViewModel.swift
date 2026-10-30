import Combine
import Foundation
import UniEatCore

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var kind: ReportKind
    @Published var note = ""
    @Published var minutes = 15
    @Published private(set) var confirmationMessage: String?
    @Published private(set) var errorText: String?
    @Published private(set) var isSending = false
    private let menu: DailyMenu
    private let reports: ReportingFacade
    private var requestID = UUID()
    private let waitObservation: Bool
    init(menu: DailyMenu, kind: ReportKind, reports: ReportingFacade, waitObservation: Bool = false) {
        self.menu = menu; self.kind = kind; self.reports = reports
        self.waitObservation = waitObservation
    }
    func send() async {
        guard !isSending else { return }
        isSending = true; errorText = nil
        defer { isSending = false }
        do {
            let status = try await reports.submitReport(for: menu, kind: kind, note: note,
                waitMinutes: waitObservation ? minutes : nil, requestID: requestID)
            confirmationMessage = switch status {
            case "pending": "Gracias. Tu reporte quedó pendiente de revisión."
            case "confirmed": "Gracias. Otros estudiantes reportaron lo mismo: el cambio quedó confirmado."
            case "dismissed": "Tu reporte ya fue revisado y descartado."
            case "queued": "Tu reporte quedó guardado y se enviará cuando el servicio esté disponible."
            case "needs_review": "El servidor rechazó el envío. Tu reporte sigue guardado para revisión desde Perfil."
            default: "Gracias. Tu observación quedó registrada."
            }
            // A subsequent wait update is a new observation; retries of this submission keep its ID.
            requestID = UUID()
        } catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }
}
