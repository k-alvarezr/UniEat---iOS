import Foundation

/// tasas del periodo sobre las impresiones, si hay muy pocos datos el server no las manda
public struct PerformanceRates: Codable, Sendable {
    public let detailOpenRate: Double    // detailOpens / impressions
    public let selectionRate: Double     // selections / impressions
}
