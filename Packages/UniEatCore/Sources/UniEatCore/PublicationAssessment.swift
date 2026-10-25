import Foundation

public enum PublicationState: Equatable, Sendable {
    case active
    case expiring
    case expired
}

/// estado de la tarjeta a cierta hora, por vencer cuando quedan 30 min o menos
public struct PublicationAssessment: Equatable, Sendable {
    public let state: PublicationState
    public let pendingReports: Int

    public init(menu: DailyMenu, at date: Date = .now) {
        if !menu.isActive(at: date) {
            state = .expired         // vencido si ya no esta activo
        } else if menu.validUntil.timeIntervalSince(date) <= 30 * 60 {
            state = .expiring        // por vencer si faltan 30min para expirar
        } else {
            state = .active          // vigente
        }
        pendingReports = menu.pendingReports
    }
}
