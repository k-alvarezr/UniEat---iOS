import Foundation

/// tipos de reporte que puede hacer el estudiante
public enum ReportKind: String, CaseIterable, Codable, Sendable {
    case unavailable
    case price
    case longLine = "long_line" // diferente porque en el back es long_line, el resto si se llaman igual que el back
    case location
    case accurate
    case arrival

    /// las discrepancias (cosas que el restaurante publico que estan mal) quedan pendientes, lo demas son observaciones
    public var isDiscrepancy: Bool { [.unavailable, .price, .location].contains(self) }
}
