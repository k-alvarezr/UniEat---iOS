import Foundation

struct PublicationTimingSnapshot: Codable, Sendable {
    let periodDays: Int
    let asOf: Date
    let minimumSessions: Int
    let groups: [PublicationTimingGroup]
}

struct PublicationTimingGroup: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let slots: [PublicationTimingSlot]
}

struct PublicationTimingSlot: Codable, Identifiable, Sendable {
    let startHour: Int
    let endHour: Int
    let publications: Int
    let exposedPairs: Int
    let detailOpenRate: Double?

    var id: Int { startHour }
}
