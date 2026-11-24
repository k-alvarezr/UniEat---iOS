import SwiftUI
import UniEatCore

/// un restaurante donde el usuario reporto, con cuantos reportes tiene en cada estado
/// es lo que manda GET /me/reports/places, todo Sendable para poder pasarlo entre hilos
struct ReportedRestaurant: Codable, Identifiable, Hashable, Sendable {
    let establishmentId: UUID
    let name: String
    let area: String
    let total: Int
    let pending: Int        // discrepancias que siguen en revision
    let confirmed: Int
    let dismissed: Int
    let lastReportAt: Date
    var id: UUID { establishmentId }
    var resolved: Int { confirmed + dismissed }
}

/// un reporte del usuario en un restaurante, sale de GET /me/reports/places/:id
struct UserReport: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: String
    let version: Int
    let menuTitle: String
    let note: String
    let observedWaitMinutes: Int?
    let status: String              // pending | confirmed | dismissed | observation
    let resolutionSource: String?   // community | admin, nil si no se ha resuelto
    let observedAt: Date
    let resolvedAt: Date?
}

/// respuesta de GET /me/reports/places, el server la llama places
struct ReportedRestaurantsResponse: Decodable, Sendable {
    let serverNow: Date
    let restaurants: [ReportedRestaurant]
    private enum CodingKeys: String, CodingKey { case serverNow, restaurants = "places" }
}

/// respuesta de GET /me/reports/places/:id, el server llama place al restaurante
struct ReportedRestaurantDetailResponse: Decodable, Sendable {
    let serverNow: Date
    let restaurant: ReportedRestaurant
    let reports: [UserReport]
    private enum CodingKeys: String, CodingKey { case serverNow, restaurant = "place", reports }
}

/// filtro de la lista de restaurantes, las observaciones no tienen estado que seguir y se ven en Todos
enum ReportHistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, inReview, resolved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Todos"
        case .inReview: "En revisión"
        case .resolved: "Resueltos"
        }
    }
    /// un restaurante entra si tiene al menos un reporte de ese tipo
    func matches(_ restaurant: ReportedRestaurant) -> Bool {
        switch self {
        case .all: true
        case .inReview: restaurant.pending > 0
        case .resolved: restaurant.resolved > 0
        }
    }
}

/// titulo e icono de cada tipo de reporte, los usan los reportes enviados y los que siguen en la cola
extension ReportKind {
    var historyTitle: String {
        switch self {
        case .unavailable: "Plato agotado o no disponible"
        case .price: "Precio distinto al publicado"
        case .location: "Ubicación difícil de encontrar"
        case .longLine: "Fila demasiado larga"
        case .accurate: "El menú estaba correcto"
        case .arrival: "Llegué al local"
        }
    }
    var historyIcon: String {
        switch self {
        case .unavailable: "fork.knife"
        case .price: "tag"
        case .location: "mappin.slash"
        case .longLine: "person.3"
        case .accurate: "checkmark.circle"
        case .arrival: "figure.walk"
        }
    }
}

/// textos y colores de cada reporte, para que la lista y el detalle digan lo mismo
extension UserReport {
    var kindTitle: String { ReportKind(rawValue: kind)?.historyTitle ?? "Reporte" }
    var kindIcon: String { ReportKind(rawValue: kind)?.historyIcon ?? "flag" }
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
