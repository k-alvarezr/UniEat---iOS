import Foundation
import SwiftData
import UniEatCore

/// Value sent from the persistence actor to MainActor. This retains the old Codable migration shape.
struct SavedMenuEntry: Codable, Identifiable, Sendable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

@Model
final class SavedMenu {
    @Attribute(.unique) var key: String
    var userID: UUID
    var menuID: UUID
    var savedAt: Date
    /// Menu metadata without dishes: the related SavedDish rows are authoritative for the dishes.
    var metadata: Data
    @Relationship(deleteRule: .cascade, inverse: \SavedDish.menu) var dishes: [SavedDish] = []
    init(userID: UUID, entry: SavedMenuEntry) throws {
        key = "\(userID):\(entry.menu.id)"; self.userID = userID; menuID = entry.menu.id; savedAt = entry.savedAt
        metadata = try UniEatDates.encoder().encode(entry.menu.replacing(items: []))
    }
}

@Model
final class SavedDish {
    var dishID: UUID
    var position: Int
    var name: String
    var detail: String
    var category: String
    var priceCop: Int
    var dietaryTags: [String]
    var dietaryKnown: Bool
    var menu: SavedMenu?
    init(dish: MenuDish, position: Int) {
        dishID = dish.id; self.position = position; name = dish.name; detail = dish.description
        category = dish.category; priceCop = dish.priceCop; dietaryTags = dish.dietaryTags; dietaryKnown = dish.dietaryKnown
    }
    var value: MenuDish {
        MenuDish(id: dishID, name: name, description: detail, category: category, priceCop: priceCop,
                 dietaryTags: dietaryTags, dietaryKnown: dietaryKnown)
    }
}

struct CachedFeedSnapshot: Codable, Sendable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
    var timeReference: ServerTimeReference?
}

@Model
final class FeedCacheRecord {
    @Attribute(.unique) var key: String
    var userID: UUID
    var isCatalog: Bool
    var fetchedAt: Date
    var payload: Data
    init(key: String, userID: UUID, isCatalog: Bool, fetchedAt: Date, payload: Data) {
        self.key = key; self.userID = userID; self.isCatalog = isCatalog
        self.fetchedAt = fetchedAt; self.payload = payload
    }
}

enum FeedCacheKey {
    static func make(userID: UUID, filters: FeedFilters) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return userID.uuidString + ":" + ((try? encoder.encode(filters).base64EncodedString()) ?? "invalid")
    }
}
