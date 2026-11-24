import Foundation

/// lo que se muestra de un restaurante en Mis reportes: su resumen, sus reportes y de cuando es la copia
struct ReportedRestaurantSnapshot: Sendable {
    let restaurant: ReportedRestaurant
    let reports: [UserReport]
    let lastSyncDate: Date?
}

/// los ultimos restaurantes abiertos en Mis reportes en memoria con una LRU
/// volver a un restaurante que se acaba de abrir no lee la base, sale al instante
/// guarda maximo 2, al abrir el 3ro se bota el que se uso hace mas tiempo
/// igual que DetailMemoryCache: un diccionario + un arreglo con el orden de uso, con 2 entradas recorrerlo es inmediato
/// no tiene vencimiento: lo que sale de aca se muestra de una y el detalle igual se refresca con el server
@MainActor
final class ReportedRestaurantMemoryCache {
    private var entries: [String: ReportedRestaurantSnapshot] = [:]   // llave usuario:restaurante -> copia
    private var order: [String] = []                                  // llaves del uso mas viejo al mas nuevo
    let capacity = 2                                                  // lo normal es ir y volver entre dos restaurantes

    var count: Int { entries.count }

    // usuario y restaurante juntos, asi una cuenta nunca ve lo que guardo otra
    private func key(_ userID: UUID, _ establishmentID: UUID) -> String {
        "\(userID.uuidString):\(establishmentID.uuidString)"
    }

    /// la copia del restaurante si esta en memoria y la marca como usada, nil si no esta
    func value(userID: UUID, establishmentID: UUID) -> ReportedRestaurantSnapshot? {
        let key = key(userID, establishmentID)
        guard let snapshot = entries[key] else { return nil }
        markUsed(key)
        return snapshot
    }

    /// guarda la copia como la mas reciente, si se pasa de 2 se bota la usada hace mas tiempo
    func insert(_ snapshot: ReportedRestaurantSnapshot, userID: UUID) {
        let key = key(userID, snapshot.restaurant.establishmentId)
        entries[key] = snapshot
        markUsed(key)
        if order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// al cambiar de cuenta se bota todo
    func clear() {
        entries = [:]
        order = []
    }

    // pone la llave al final, como la usada mas recientemente
    private func markUsed(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
