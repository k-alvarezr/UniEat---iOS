import Combine
import Foundation
import UniEatCore

@MainActor
/// estado de la hoja de reportar que antes estaba en ReportSheet
/// se crea uno cada vez que se abre la hoja (AppStore.makeReport) y manda por ReportingFacade
final class ReportViewModel: ObservableObject {
    @Published var kind: ReportKind
    @Published var note = ""
    // minutos de fila, solo se mandan si el tipo es fila larga
    @Published var minutes = 15
    @Published private(set) var confirmationMessage: String?
    @Published private(set) var errorText: String?
    @Published private(set) var isSending = false
    private let menu: DailyMenu
    private let reports: ReportingFacade
    // id fijo de este reporte, si se toca enviar otra vez no se duplica
    private var requestID = UUID()
    init(menu: DailyMenu, kind: ReportKind, reports: ReportingFacade) {
        self.menu = menu; self.kind = kind; self.reports = reports
    }
    /// manda el reporte y traduce el estado del server a un mensaje para el estudiante
    /// queued es que quedo guardado sin red, needs_review que el server lo rechazo y sigue guardado
    func send() async {
        guard !isSending else { return }
        isSending = true; errorText = nil
        defer { isSending = false }
        do {
            let status = try await reports.submitReport(for: menu, kind: kind, note: note,
                waitMinutes: kind == .longLine ? minutes : nil, requestID: requestID)
            confirmationMessage = switch status {
            case "pending": "Gracias. Tu reporte quedó pendiente de revisión."
            case "confirmed": "Gracias. Otros estudiantes reportaron lo mismo: el cambio quedó confirmado."
            case "dismissed": "Tu reporte ya fue revisado y descartado."
            case "queued": "Tu reporte quedó guardado y se enviará cuando el servicio esté disponible."
            case "needs_review": "El servidor rechazó el envío. Tu reporte sigue guardado para revisión desde Perfil."
            default: "Gracias. Tu observación quedó registrada."
            }
            // si vuelve a mandar la fila es una observacion nueva con id nuevo
            // los reintentos de este mismo envio conservan el id de antes
            requestID = UUID()
        } catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }
}
