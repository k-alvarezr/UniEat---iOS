import Foundation
import UniEatCore

/// copia de los detalles en memoria con una LRU (least recently used)
/// abrir otra vez un detalle reciente no lee el disco ni decodifica el json, sale al instante
/// guarda maximo 20, al abrir el 21 se bota el que se uso hace mas tiempo
/// la lru es un diccionario + un arreglo con el orden de uso, con 20 entradas recorrerlo es rapido, para que una enlazada
@MainActor
final class DetailMemoryCache {
    // el detalle con la hora en que se guardo, para revisar si ya vencio
    private struct Entry {
        let detail: MenuDetail
        let savedAt: Date
    }
    private var entries: [String: Entry] = [:]   // llave usuario:menu -> detalle
    private var order: [String] = []             // llaves del uso mas viejo al mas nuevo
    private let now: () -> Date                  // hora inyectada para poder probar el vencimiento
    let capacity = 20                            // 20 detalles, mas de los que alguien abre en un rato espero
    let ttl: TimeInterval = 60                   // un detalle dura 60 s, despues se vuelve a leer del disco o del server
    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    var count: Int { entries.count }

    // usuario y menu juntos, asi una cuenta nunca ve el detalle que guardo otra
    private func key(_ userID: UUID, _ menuID: UUID) -> String {
        "\(userID.uuidString):\(menuID.uuidString)"
    }

    /// el detalle si tiene menos de 60 s y lo marca como usado, si ya vencio se borra y devuelve nil
    func value(userID: UUID, menuID: UUID) -> MenuDetail? {
        let key = key(userID, menuID)
        guard let entry = entries[key] else { return nil }   // hay algo guardado con esa llave?
        let age = now().timeIntervalSince(entry.savedAt)
        guard age >= 0, age < ttl else {
            remove(key)
            return nil
        }
        markUsed(key)
        return entry.detail
    }

    /// guarda el detalle como el mas reciente, si se pasa de 20 se bota el usado hace mas tiempo
    func insert(_ detail: MenuDetail, userID: UUID) {
        let key = key(userID, detail.menu.id)
        entries[key] = Entry(detail: detail, savedAt: now())
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

    // saca un detalle vencido
    private func remove(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}
