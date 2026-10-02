import Foundation

/// Estado de vigencia calculado por el servidor con su propia hora (BQ-04).
/// No depende del reloj del teléfono, que puede estar desajustado.
public enum ServerPublicationStatus: String, Codable, Sendable {
    case active
    case expiring
    case expired
    case closed

    public var label: String {
        switch self {
        case .active: return "Vigente"
        case .expiring: return "Por vencer"
        case .expired: return "Vencido"
        case .closed: return "Cerrado"
        }
    }

    /// Solo una publicación visible en el feed admite reportes y elecciones.
    public var acceptsActions: Bool { self == .active || self == .expiring }
}

/// Reporte de la versión consultada, sin autor ni nota (privacidad del estudiante que reportó).
public struct ReportSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: String
    public let status: String
    public let createdAt: Date

    public init(id: UUID, kind: String, status: String, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
    }

    public var isPending: Bool { status == "pending" }

    public var kindLabel: String {
        switch ReportKind(rawValue: kind) {
        case .unavailable: return "Plato agotado o no disponible"
        case .price: return "Precio distinto al publicado"
        case .location: return "Ubicación difícil de encontrar"
        case .longLine: return "Fila más larga"
        case .accurate: return "El menú sigue correcto"
        case .arrival: return "Llegada al local"
        case nil: return "Otro cambio"
        }
    }

    public var statusLabel: String {
        switch status {
        case "pending": return "Pendiente de revisión"
        case "confirmed": return "Confirmado"
        case "dismissed": return "Descartado"
        default: return "Observación"
        }
    }
}

/// Respuesta de `GET /menus/:id`: la versión actual del menú más su estado y reportes.
/// El objeto `menu` se lee dos veces: como `DailyMenu` (lo que ya usan las vistas) y para
/// los campos que `DailyMenu` no tiene, así el feed y el modo demo no cambian.
public struct MenuDetail: Decodable, Sendable {
    public let menu: DailyMenu
    public let status: ServerPublicationStatus
    public let currentVersion: Int
    public let reports: [ReportSummary]
    public let serverNow: Date

    public init(menu: DailyMenu, status: ServerPublicationStatus, currentVersion: Int,
                reports: [ReportSummary], serverNow: Date) {
        self.menu = menu
        self.status = status
        self.currentVersion = currentVersion
        self.reports = reports
        self.serverNow = serverNow
    }

    private enum CodingKeys: String, CodingKey { case menu, serverNow }

    private struct Extras: Decodable {
        let status: ServerPublicationStatus
        let currentVersion: Int
        let reports: [ReportSummary]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menu = try container.decode(DailyMenu.self, forKey: .menu)
        let extras = try container.decode(Extras.self, forKey: .menu)
        status = extras.status
        currentVersion = extras.currentVersion
        reports = extras.reports ?? []
        serverNow = try container.decode(Date.self, forKey: .serverNow)
    }

    /// Estado a la hora `date`. Parte del estado que dio el servidor y lo avanza con el reloj
    /// mientras la vista sigue abierta: un menú "Por vencer" pasa a "Vencido" al llegar a
    /// `validUntil` sin esperar otra consulta. Cerrado o vencido nunca vuelve atrás.
    public func status(at date: Date) -> ServerPublicationStatus {
        switch status {
        case .closed, .expired:
            return status
        case .active, .expiring:
            if date >= menu.validUntil { return .expired }
            if menu.validUntil.timeIntervalSince(date) <= 30 * 60 { return .expiring }
            return status
        }
    }

    /// Reportes que todavía no revisa un administrador; no cambian el menú oficial.
    public var pendingReports: [ReportSummary] { reports.filter(\.isPending) }

    /// true si el estudiante abrió una versión anterior a la que existe ahora en el servidor.
    public func isNewer(than version: Int) -> Bool { currentVersion > version }
}
