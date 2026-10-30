import Combine
import Foundation
import UniEatCore

/// estado de la hoja de reportar que antes estaba en ReportSheet
/// se crea uno cada vez que se abre la hoja (AppStore.makeReport) y manda por ReportingFacade
@MainActor
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
    private let waitObservation: Bool   // true si es un reporte de fila desde el piloto, ahi si van los minutos
    init(menu: DailyMenu, kind: ReportKind, reports: ReportingFacade, waitObservation: Bool = false) {
        self.menu = menu
        self.kind = kind
        self.reports = reports
        self.waitObservation = waitObservation
    }
    /// manda el reporte y traduce el resultado a un mensaje para el estudiante
    func send() async {
        guard !isSending else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            let result = try await reports.submitReport(for: menu, kind: kind, note: note,
                waitMinutes: waitObservation ? minutes : nil, requestID: requestID)
            confirmationMessage = switch result {
            case .sent("pending"): "Gracias. Tu reporte quedó pendiente de revisión."
            case .sent("confirmed"): "Gracias. Otros estudiantes reportaron lo mismo: el cambio quedó confirmado."
            case .sent("dismissed"): "Tu reporte ya fue revisado y descartado."
            case .sent: "Gracias. Tu observación quedó registrada."
            case .queued: "Tu reporte quedó guardado y se enviará cuando el servicio esté disponible."
            case .needsReview: "El servidor rechazó el envío. Tu reporte sigue guardado para revisión desde Perfil."
            }
            // si vuelve a mandar la fila es una observacion nueva con id nuevo
            // los reintentos de este mismo envio conservan el id de antes
            requestID = UUID()
        } catch is CancellationError { }
        catch { errorText = error.localizedDescription }
    }
}
