import Foundation

/// plato de un menu con su precio y dieta
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
