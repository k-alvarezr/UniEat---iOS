import Foundation
import SwiftData
import UniEatCore

/// un menu guardado como valor normal, es lo que el actor le devuelve a las pantallas
/// tiene la misma forma que se guardaba antes en UserDefaults, asi se pueden migrar
struct SavedMenuEntry: Codable, Identifiable, Sendable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

/// menu guardado en swiftdata (#34), una fila por usuario y menu, es la tabla padre de sus platos
@Model
final class SavedMenu {
    @Attribute(.unique) var key: String   // usuario:menu, para no repetir filas
    var userID: UUID
    var menuID: UUID
    var savedAt: Date
    /// datos del menu sin los platos, los platos estan en las filas SavedDish relacionadas
    var metadata: Data
    // si se borra el menu se borran sus platos
    @Relationship(deleteRule: .cascade, inverse: \SavedDish.menu) var dishes: [SavedDish] = []
    init(userID: UUID, entry: SavedMenuEntry) throws {
        key = "\(userID):\(entry.menu.id)"
        self.userID = userID
        menuID = entry.menu.id
        savedAt = entry.savedAt
        metadata = try UniEatDates.encoder().encode(entry.menu.replacing(items: []))
    }
}

/// plato de un menu guardado, cuelga de SavedMenu (relacion 1 -> n)
@Model
final class SavedDish {
    var dishID: UUID
    var position: Int   // orden del plato dentro del menu
    var name: String
    var detail: String
    var category: String
    var priceCop: Int
    var dietaryTags: [String]
    var dietaryKnown: Bool
    var menu: SavedMenu?
    init(dish: MenuDish, position: Int) {
        dishID = dish.id
        self.position = position
        name = dish.name
        detail = dish.description
        category = dish.category
        priceCop = dish.priceCop
        dietaryTags = dish.dietaryTags
        dietaryKnown = dish.dietaryKnown
    }
    /// el plato de vuelta como MenuDish para las pantallas
    var value: MenuDish {
        MenuDish(id: dishID, name: name, description: detail, category: category, priceCop: priceCop,
                 dietaryTags: dietaryTags, dietaryKnown: dietaryKnown)
    }
}

/// una copia del feed: de quien es, con que filtros y lo que respondio el server
struct CachedFeedSnapshot: Codable, Sendable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
    var timeReference: ServerTimeReference? = nil
}

/// copia del feed guardada en swiftdata (#34), una fila por usuario y filtros, o el catalogo completo
/// la copia va como json en payload porque se lee entera, no se consulta por campos
@Model
final class FeedCacheRecord {
    @Attribute(.unique) var key: String   // usuario:filtros, o usuario:catalog
    var userID: UUID
    var isCatalog: Bool                   // true si es el catalogo completo sin filtros
    var fetchedAt: Date
    var payload: Data
    init(key: String, userID: UUID, isCatalog: Bool, fetchedAt: Date, payload: Data) {
        self.key = key
        self.userID = userID
        self.isCatalog = isCatalog
        self.fetchedAt = fetchedAt
        self.payload = payload
    }
}

/// llave de una copia: el usuario mas los filtros en json ordenado
/// ordenado para que los mismos filtros siempre den la misma llave
enum FeedCacheKey {
    static func make(userID: UUID, filters: FeedFilters) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return userID.uuidString + ":" + ((try? encoder.encode(filters).base64EncodedString()) ?? "invalid")
    }
}
