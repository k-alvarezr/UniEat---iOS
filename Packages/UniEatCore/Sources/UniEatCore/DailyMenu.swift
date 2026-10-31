import Foundation

/// una version del menu del dia tal cual la manda la api
public struct DailyMenu: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let version: Int
    public let validUntil: Date
    public let publishedAt: Date
    public let closedAt: Date?
    public let establishmentId: UUID
    public let establishmentName: String
    public let area: String
    public let address: String
    public let entranceDescription: String
    public let latitude: Double?
    public let longitude: Double?
    public let photoUrl: String?
    public let paymentMethods: [String]
    public let isVerified: Bool
    public let items: [MenuDish]
    public let lowestPriceCop: Int
    public let waitMinutes: Int?
    public let waitSampleCount: Int
    public let waitNewestReportAt: Date?
    // BQ-07: lo habitual del local a esta hora, el server lo manda solo si no hay 3 reportes recientes
    public let waitHistoricalMinutes: Int?
    public let waitHistoricalSampleCount: Int?
    public let pendingReports: Int
    /// por que el server puso este menu en ese lugar del feed
    public let explanation: String

    public init(id: UUID = UUID(), title: String, version: Int = 1, validUntil: Date, publishedAt: Date = .now,
                closedAt: Date? = nil, establishmentId: UUID = UUID(), establishmentName: String,
                area: String, address: String, entranceDescription: String = "",
                latitude: Double? = nil, longitude: Double? = nil, photoUrl: String? = nil,
                paymentMethods: [String] = [], isVerified: Bool = false, items: [MenuDish], lowestPriceCop: Int,
                waitMinutes: Int? = nil, waitSampleCount: Int = 0, waitNewestReportAt: Date? = nil,
                waitHistoricalMinutes: Int? = nil, waitHistoricalSampleCount: Int? = nil,
                pendingReports: Int = 0, explanation: String = "Menú vigente") {
        self.id = id
        self.title = title
        self.version = version
        self.validUntil = validUntil
        self.publishedAt = publishedAt
        self.closedAt = closedAt
        self.establishmentId = establishmentId
        self.establishmentName = establishmentName
        self.area = area
        self.address = address
        self.entranceDescription = entranceDescription
        self.latitude = latitude
        self.longitude = longitude
        self.photoUrl = photoUrl
        self.paymentMethods = paymentMethods
        self.isVerified = isVerified
        self.items = items
        self.lowestPriceCop = lowestPriceCop
        self.waitMinutes = waitMinutes
        self.waitSampleCount = waitSampleCount
        self.waitNewestReportAt = waitNewestReportAt
        self.waitHistoricalMinutes = waitHistoricalMinutes
        self.waitHistoricalSampleCount = waitHistoricalSampleCount
        self.pendingReports = pendingReports
        self.explanation = explanation
    }

    /// publicado, sin cerrar y antes de vencer
    public func isActive(at date: Date = .now) -> Bool {
        if let closedAt, closedAt <= date { return false }
        return publishedAt <= date && validUntil > date
    }

    /// la fila solo se estima con 3 reportes o mas y el ultimo de hace 30 min o menos
    public func hasWaitEvidence(at date: Date = .now) -> Bool {
        guard waitSampleCount >= 3, waitMinutes != nil, let newest = waitNewestReportAt else { return false }
        return newest <= date && date.timeIntervalSince(newest) <= 30 * 60
    }

    public var hasWaitEvidence: Bool { hasWaitEvidence(at: .now) }
}
