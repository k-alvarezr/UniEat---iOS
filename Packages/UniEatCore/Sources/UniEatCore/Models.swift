import Foundation

public struct MenuDish: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let category: String
    public let priceCop: Int
    public let dietaryTags: [String]
    public let dietaryKnown: Bool

    public init(id: UUID = UUID(), name: String, description: String = "", category: String = "Almuerzo", priceCop: Int, dietaryTags: [String] = [], dietaryKnown: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.priceCop = priceCop
        self.dietaryTags = dietaryTags
        self.dietaryKnown = dietaryKnown
    }
}

public struct DailyMenu: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let version: Int
    public let validUntil: Date
    public let publishedAt: Date
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
    public let relevanceScore: Int
    public let explanation: String

    public init(id: UUID = UUID(), title: String, version: Int = 1, validUntil: Date, publishedAt: Date = .now,
                establishmentId: UUID = UUID(), establishmentName: String, area: String, address: String,
                entranceDescription: String = "", latitude: Double? = nil, longitude: Double? = nil,
                photoUrl: String? = nil, paymentMethods: [String] = [], isVerified: Bool = false,
                items: [MenuDish], lowestPriceCop: Int, waitMinutes: Int? = nil, waitSampleCount: Int = 0,
                waitNewestReportAt: Date? = nil, pendingReports: Int = 0, relevanceScore: Int = 0,
                explanation: String = "Menú vigente") {
        self.id = id
        self.title = title
        self.version = version
        self.validUntil = validUntil
        self.publishedAt = publishedAt
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
        self.relevanceScore = relevanceScore
        self.explanation = explanation
    }

    public func isActive(at date: Date = .now) -> Bool { publishedAt <= date && validUntil > date }
    public func hasWaitEvidence(at date: Date = .now) -> Bool {
        guard waitSampleCount >= 3, waitMinutes != nil, let newest = waitNewestReportAt else { return false }
        return newest <= date && date.timeIntervalSince(newest) <= 30 * 60
    }
    public var hasWaitEvidence: Bool { hasWaitEvidence(at: .now) }

    public func revised(title: String, establishmentName: String, area: String, address: String,
                        entranceDescription: String,
                        validUntil: Date, items: [MenuDish], paymentMethods: [String],
                        at date: Date = .now) -> DailyMenu {
        DailyMenu(id: id, title: title, version: version + 1, validUntil: validUntil,
             publishedAt: date, establishmentId: establishmentId,
             establishmentName: establishmentName, area: area, address: address,
             entranceDescription: entranceDescription, latitude: latitude, longitude: longitude,
             photoUrl: photoUrl, paymentMethods: paymentMethods, isVerified: isVerified,
             items: items, lowestPriceCop: items.map(\.priceCop).min() ?? 0,
             explanation: "Publicación actualizada")
    }

    public func closed(at date: Date = .now) -> DailyMenu {
        revised(title: title, establishmentName: establishmentName, area: area,
                address: address, entranceDescription: entranceDescription,
                validUntil: date, items: items,
                paymentMethods: paymentMethods, at: date)
    }
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

public struct PerformanceSummary: Codable, Sendable {
    public let periodDays: Int
    public let impressions: Int
    public let detailOpens: Int
    public let selections: Int
    public let reportedArrivals: Int

    public init(periodDays: Int, impressions: Int, detailOpens: Int, selections: Int, reportedArrivals: Int) {
        self.periodDays = periodDays
        self.impressions = impressions
        self.detailOpens = detailOpens
        self.selections = selections
        self.reportedArrivals = reportedArrivals
    }
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

public struct Establishment: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ownerId: UUID?
    public let name: String
    public let area: String
    public let address: String
    public let entranceDescription: String
    public let latitude: Double?
    public let longitude: Double?
    public let photoUrl: String?
    public let paymentMethods: [String]
    public let isVerified: Bool
}

public enum ReportKind: String, CaseIterable, Codable, Sendable {
    case unavailable
    case price
    case longLine = "long_line"
    case location
    case accurate
    case arrival
}

public enum UniEatDates {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let text = try source.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try source.singleValueContainer(), debugDescription: "Invalid ISO8601 date: \(text)")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
