import Foundation

public struct PerformanceRates: Codable, Sendable {
    public let detailOpenRate: Double    // detailOpens / impressions
    public let selectionRate: Double     // selections / impressions
}
