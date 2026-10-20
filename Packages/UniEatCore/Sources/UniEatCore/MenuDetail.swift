import Foundation

/// estado de vigencia que calcula el server con su hora BQ-04
/// no depende del reloj del celular que puede estar mal
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

    /// solo si se ve en el feed se puede reportar o elegir
    public var acceptsActions: Bool { self == .active || self == .expiring }
}

/// reporte de la version, sin autor ni nota para cuidar al estudiante que reporto
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

/// respuesta de GET /menus/:id, version actual del menu con estado y reportes
/// el objeto menu se lee dos veces, una como DailyMenu que es lo que usan las vistas
/// y otra para lo que solo trae el detalle
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

    /// estado a la hora date, arranca con lo que dijo el server y avanza con el reloj
    /// mientras la pantalla siga abierta, por vencer pasa a vencido al llegar a validUntil
    /// sin pedir nada, cerrado o vencido nunca se devuelve
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

    /// reportes que todavia no revisa un admin
    public var pendingReports: [ReportSummary] { reports.filter(\.isPending) }

    /// los descartados no se muestran
    public var activeNotices: [ReportSummary] { reports.filter { $0.isPending || $0.status == "confirmed" } }

    /// true si el estudiante abrio una version mas vieja que la que hay ahora en el server
    public func isNewer(than version: Int) -> Bool { currentVersion > version }
}
