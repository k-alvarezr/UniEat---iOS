import SwiftUI
import UniEatCore

/// un restaurante donde el usuario reporto, con cuantos reportes tiene en cada estado
/// es lo que manda GET /me/reports/places, todo Sendable para poder pasarlo entre hilos
struct ReportHistoryPlace: Codable, Identifiable, Hashable, Sendable {
    let establishmentId: UUID
    let name: String
    let area: String
    let photoUrl: String?
    let total: Int
    let pending: Int        // discrepancias que siguen en revision
    let confirmed: Int
    let dismissed: Int
    let observations: Int   // fila, llegada o "todo bien", nunca quedan pendientes
    let lastReportAt: Date
    var id: UUID { establishmentId }
    var resolved: Int { confirmed + dismissed }
}

/// un reporte del usuario en un restaurante, sale de GET /me/reports/places/:id
struct ReportHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: String
    let publicationId: UUID
    let version: Int
    let menuTitle: String
    let note: String
    let observedWaitMinutes: Int?
    let status: String              // pending | confirmed | dismissed | observation
    let resolutionSource: String?   // community | admin, nil si no se ha resuelto
    let createdAt: Date
    let observedAt: Date
    let resolvedAt: Date?
}

struct ReportHistoryPlacesResponse: Decodable, Sendable {
    let serverNow: Date
    let places: [ReportHistoryPlace]
}

struct ReportHistoryPlaceResponse: Decodable, Sendable {
    let serverNow: Date
    let place: ReportHistoryPlace
    let reports: [ReportHistoryEntry]
}

/// filtro de la lista de restaurantes
enum ReportHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, inReview, resolved, observations
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Todos"
        case .inReview: "En revisión"
        case .resolved: "Resueltos"
        case .observations: "Observaciones"
        }
    }
    /// un restaurante entra si tiene al menos un reporte de ese tipo
    func includes(_ place: ReportHistoryPlace) -> Bool {
        switch self {
        case .all: true
        case .inReview: place.pending > 0
        case .resolved: place.resolved > 0
        case .observations: place.observations > 0
        }
    }
}

/// textos y colores de cada reporte, para que la lista y el detalle digan lo mismo
extension ReportHistoryEntry {
    var kindTitle: String {
        switch ReportKind(rawValue: kind) {
        case .unavailable: "Plato agotado o no disponible"
        case .price: "Precio distinto al publicado"
        case .location: "Ubicación difícil de encontrar"
        case .longLine: "Fila demasiado larga"
        case .accurate: "El menú estaba correcto"
        case .arrival: "Llegué al local"
        case nil: "Reporte"
        }
    }
    var kindIcon: String {
        switch ReportKind(rawValue: kind) {
        case .unavailable: "fork.knife"
        case .price: "tag"
        case .location: "mappin.slash"
        case .longLine: "person.3"
        case .accurate: "checkmark.circle"
        case .arrival: "figure.walk"
        case nil: "flag"
        }
    }
    var statusTitle: String {
        switch status {
        case "pending": "En revisión"
        case "confirmed": resolutionSource == "community" ? "Confirmado por la comunidad" : "Confirmado por un administrador"
        case "dismissed": "Descartado"
        default: "Registrado"
        }
    }
    var statusColor: Color {
        switch status {
        case "pending": Palette.yellow
        case "confirmed": Palette.green
        case "dismissed": Palette.coral
        default: Palette.cyan
        }
    }
}
