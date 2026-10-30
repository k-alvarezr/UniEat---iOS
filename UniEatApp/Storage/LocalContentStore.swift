import Foundation
import SwiftData
import UniEatCore

/// guardados y copias del feed en swiftdata desde un @ModelActor
/// tiene su propio contexto que trabaja fuera del hilo principal, pero usa el MISMO ModelContainer que los reportes
/// los objetos de swiftdata nunca salen del actor, afuera solo llegan valores Codable y Sendable
@ModelActor
actor LocalContentStore {
    /// menus guardados del usuario, del mas nuevo al mas viejo, con sus platos en orden
    func savedMenus(userID: UUID) throws -> [SavedMenuEntry] {
        let rows = try modelContext.fetch(FetchDescriptor<SavedMenu>(predicate: #Predicate { $0.userID == userID }))
        var entries: [SavedMenuEntry] = []
        for row in rows.sorted(by: { $0.savedAt > $1.savedAt }) {
            let metadata = try UniEatDates.decoder().decode(DailyMenu.self, from: row.metadata)
            let dishes = row.dishes.sorted { $0.position < $1.position }.map(\.value)
            entries.append(SavedMenuEntry(menu: metadata.replacing(items: dishes), savedAt: row.savedAt))
        }
        return entries
    }

    /// pasa los guardados viejos de UserDefaults a swiftdata, si ya estaba en la base gana la base
    /// se puede correr varias veces sin duplicar, y UserDefaults se borra recien cuando esto guardo bien
    func migrateSavedMenus(_ legacy: Data, userID: UUID) throws {
        let entries = try UniEatDates.decoder().decode([SavedMenuEntry].self, from: legacy)
        let existing = Set(try savedMenus(userID: userID).map(\.id))
        do {
            var seen = existing
            for entry in entries where seen.insert(entry.id).inserted {
                try insert(entry, userID: userID)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// guarda el menu si no estaba o lo quita si estaba, devuelve la lista actualizada
    func toggle(_ menu: DailyMenu, userID: UUID, savedAt: Date) throws -> [SavedMenuEntry] {
        let key = "\(userID):\(menu.id)"
        do {
            if let row = try modelContext.fetch(FetchDescriptor<SavedMenu>(predicate: #Predicate { $0.key == key })).first {
                modelContext.delete(row)   // el cascade borra solo los platos de este menu
            } else {
                try insert(SavedMenuEntry(menu: menu, savedAt: savedAt), userID: userID)
            }
            try modelContext.save()
            return try savedMenus(userID: userID)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // inserta el menu y cada plato colgado de el, sin guardar todavia
    private func insert(_ entry: SavedMenuEntry, userID: UUID) throws {
        let parent = try SavedMenu(userID: userID, entry: entry)
        modelContext.insert(parent)
        for (position, dish) in entry.menu.items.enumerated() {
            let row = SavedDish(dish: dish, position: position)
            modelContext.insert(row)
            row.menu = parent
        }
    }

    /// guarda o reemplaza la copia del feed de esos filtros, o el catalogo
    /// se quedan maximo 24 copias por usuario (sin contar el catalogo), las mas viejas se borran
    func saveFeed(_ snapshot: CachedFeedSnapshot, isCatalog: Bool = false, permit: WritePermit) throws {
        try permit.check()
        let key = isCatalog ? "\(snapshot.userId):catalog" : FeedCacheKey.make(userID: snapshot.userId, filters: snapshot.filters)
        let data = try UniEatDates.encoder().encode(snapshot)
        do {
            if let row = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })).first {
                // un guardado que llega tarde no pisa una respuesta mas nueva
                guard row.fetchedAt <= snapshot.response.fetchedAt else { return }
                row.payload = data
                row.fetchedAt = snapshot.response.fetchedAt
            } else {
                modelContext.insert(FeedCacheRecord(key: key, userID: snapshot.userId, isCatalog: isCatalog,
                    fetchedAt: snapshot.response.fetchedAt, payload: data))
            }
            let userID = snapshot.userId
            let rows = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.userID == userID }))
                .filter { !$0.isCatalog }
                .sorted { $0.fetchedAt > $1.fetchedAt }
            for old in rows.dropFirst(24) {
                modelContext.delete(old)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// reportes y copias se borran en una sola transaccion, los guardados se quedan
    /// porque son marcadores del usuario, cuando la sesion vence sola esto nunca se llama
    func forget(userID: UUID) throws {
        do {
            let reports = try modelContext.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.userId == userID }))
            let feeds = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.userID == userID }))
            for row in reports { modelContext.delete(row) }
            for row in feeds { modelContext.delete(row) }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// la copia del feed de esos filtros, o el catalogo, nil si nunca se guardo
    func feed(userID: UUID, filters: FeedFilters, catalog: Bool = false) throws -> CachedFeedSnapshot? {
        let key = catalog ? "\(userID):catalog" : FeedCacheKey.make(userID: userID, filters: filters)
        guard let row = try modelContext.fetch(FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })).first else { return nil }
        return try UniEatDates.decoder().decode(CachedFeedSnapshot.self, from: row.payload)
    }
}
