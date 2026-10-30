import Foundation
import SwiftData
import UniEatCore

/// Independent executor/context, SAME ModelContainer as Juan's report outbox.
/// SwiftData objects never escape this actor; callers receive Codable/Sendable values.
@ModelActor
actor LocalContentStore {
    func savedMenus(userID: UUID) throws -> [SavedMenuEntry] {
        let rows = try modelContext.fetch(FetchDescriptor<SavedMenu>(predicate: #Predicate { $0.userID == userID }))
        return try rows.sorted { $0.savedAt > $1.savedAt }.map { row in
            let metadata = try UniEatDates.decoder().decode(DailyMenu.self, from: row.metadata)
            return SavedMenuEntry(menu: metadata.replacing(items: row.dishes.sorted { $0.position < $1.position }.map(\.value)), savedAt: row.savedAt)
        }
    }

    /// Idempotent migration: a pre-existing database row wins. Commit before removing UserDefaults.
    func migrateSavedMenus(_ legacy: Data, userID: UUID) throws {
        let entries = try UniEatDates.decoder().decode([SavedMenuEntry].self, from: legacy)
        let existing = Set(try savedMenus(userID: userID).map(\.id))
        do {
            var seen = existing
            for entry in entries where seen.insert(entry.id).inserted { try insert(entry, userID: userID) }
            try modelContext.save()
        } catch { modelContext.rollback(); throw error }
    }

    func toggle(_ menu: DailyMenu, userID: UUID, savedAt: Date) throws -> [SavedMenuEntry] {
        let key = "\(userID):\(menu.id)"
        do {
            if let row = try modelContext.fetch(FetchDescriptor<SavedMenu>(predicate: #Predicate { $0.key == key })).first {
                modelContext.delete(row) // cascade removes only this menu's related dishes.
            } else { try insert(SavedMenuEntry(menu: menu, savedAt: savedAt), userID: userID) }
            try modelContext.save()
            return try savedMenus(userID: userID)
        } catch { modelContext.rollback(); throw error }
    }

    private func insert(_ entry: SavedMenuEntry, userID: UUID) throws {
        let parent = try SavedMenu(userID: userID, entry: entry)
        modelContext.insert(parent)
        for (position, dish) in entry.menu.items.enumerated() {
            let row = SavedDish(dish: dish, position: position)
            modelContext.insert(row); row.menu = parent
        }
    }

    func saveFeed(_ snapshot: CachedFeedSnapshot, isCatalog: Bool = false) throws {
        let key = isCatalog ? "\(snapshot.userId):catalog" : FeedCacheKey.make(userID: snapshot.userId, filters: snapshot.filters)
        let data = try UniEatDates.encoder().encode(snapshot)
        do {
            if let row = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })).first {
                row.payload = data; row.fetchedAt = snapshot.response.fetchedAt
            } else {
                modelContext.insert(FeedCacheRecord(key: key, userID: snapshot.userId, isCatalog: isCatalog,
                    fetchedAt: snapshot.response.fetchedAt, payload: data))
            }
            let userID = snapshot.userId
            let rows = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.userID == userID }))
                .filter { !$0.isCatalog }.sorted { $0.fetchedAt > $1.fetchedAt }
            for old in rows.dropFirst(24) { modelContext.delete(old) }
            try modelContext.save()
        } catch { modelContext.rollback(); throw error }
    }

    func feed(userID: UUID, filters: FeedFilters, catalog: Bool = false) throws -> CachedFeedSnapshot? {
        let key = catalog ? "\(userID):catalog" : FeedCacheKey.make(userID: userID, filters: filters)
        guard let row = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })).first else { return nil }
        return try UniEatDates.decoder().decode(CachedFeedSnapshot.self, from: row.payload)
    }
}
