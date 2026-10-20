import Foundation

public struct MenuDish: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let category: String
    public let priceCop: Int
    public let dietaryTags: [String]
    /// false si el restaurante no dijo la dieta, asi nunca sale como compatible
    public let dietaryKnown: Bool

    public init(id: UUID = UUID(), name: String, description: String = "", category: String = "Almuerzo",
                priceCop: Int, dietaryTags: [String] = [], dietaryKnown: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.priceCop = priceCop
        self.dietaryTags = dietaryTags
        self.dietaryKnown = dietaryKnown
    }
}

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
    public let pendingReports: Int
    /// por que el server puso este menu en ese lugar del feed
    public let explanation: String

    public init(id: UUID = UUID(), title: String, version: Int = 1, validUntil: Date, publishedAt: Date = .now,
                closedAt: Date? = nil, establishmentId: UUID = UUID(), establishmentName: String,
                area: String, address: String, entranceDescription: String = "",
                latitude: Double? = nil, longitude: Double? = nil, photoUrl: String? = nil,
                paymentMethods: [String] = [], isVerified: Bool = false, items: [MenuDish], lowestPriceCop: Int,
                waitMinutes: Int? = nil, waitSampleCount: Int = 0, waitNewestReportAt: Date? = nil,
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

public struct FeedFilters: Codable, Hashable, Sendable {
    public var budgetCop: Int?
    public var availableMinutes: Int?
    public var diet: String?
    public var area: String?
    public var paymentMethod: String?

    public init(budgetCop: Int? = 20_000, availableMinutes: Int? = 40, diet: String? = nil,
                area: String? = "Centro", paymentMethod: String? = nil) {
        self.budgetCop = budgetCop
        self.availableMinutes = availableMinutes
        self.diet = diet
        self.area = area
        self.paymentMethod = paymentMethod
    }
}

/// actividad de ios en un periodo, las tasas llegan vacias si hay muy pocos datos
public struct PerformanceSummary: Codable, Sendable {
    public let periodDays: Int
    public let impressions: Int
    public let detailOpens: Int
    public let selections: Int
    public let reportedArrivals: Int
    public let savedMenus: Int
    public let locationOpens: Int
    public let reports: Int
    public let sampleSize: Int?
    public let insufficientData: Bool?
    public let rates: PerformanceRates?
}

public struct PerformanceRates: Codable, Sendable {
    public let detailOpenRate: Double
    public let selectionRate: Double
}

public struct Profile: Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let role: String

    public init(id: UUID = UUID(), displayName: String, role: String) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public enum ReportKind: String, CaseIterable, Codable, Sendable {
    case unavailable
    case price
    case longLine = "long_line"
    case location
    case accurate
    case arrival

    /// las discrepancias quedan pendientes, lo demas son observaciones
    public var isDiscrepancy: Bool { [.unavailable, .price, .location].contains(self) }
}

/// fechas iso 8601 con o sin milisegundos como las manda la api
public enum UniEatDates {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(text)")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
