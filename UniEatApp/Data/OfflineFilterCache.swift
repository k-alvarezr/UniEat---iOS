import Foundation
import UniEatCore

/// Kevin: resultados de filtros locales recientes. NSCache mantiene respuestas online;
/// esta LRU evita recalcular al alternar filtros offline sin duplicar datos en disco.
@MainActor
final class OfflineFilterCache {
    private final class Node {
        let key: String
        let menus: [DailyMenu]
        let insertedAt: Date
        let expiresAt: Date
        weak var previous: Node?
        var next: Node?
        init(key: String, menus: [DailyMenu], insertedAt: Date, expiresAt: Date) {
            self.key = key
            self.menus = menus
            self.insertedAt = insertedAt
            self.expiresAt = expiresAt
        }
    }
    private var entries: [String: Node] = [:]
    private var newest: Node?
    private var oldest: Node?
    let capacity: Int
    let ttl: TimeInterval = 30
    let maximumEntryBytes = 1024 * 1024
    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    /// Diccionario + lista doble: busqueda, promocion y retirada de una entrada en O(1).
    func value(userID: UUID, filters: FeedFilters, at now: Date) -> [DailyMenu]? {
        let key = FeedCacheKey.make(userID: userID, filters: filters)
        guard let node = entries[key] else { return nil }
        guard now >= node.insertedAt, now < node.expiresAt else {
            remove(node)
            return nil
        }
        detach(node)
        promote(node)
        return node.menus
    }

    /// El coste de codificar el valor es O(n); la estructura LRU no recorre las entradas.
    /// Caduca antes de cualquier cambio temporal de elegibilidad, ademas del TTL.
    func insert(_ menus: [DailyMenu], source: [DailyMenu], userID: UUID, filters: FeedFilters, at now: Date) {
        let key = FeedCacheKey.make(userID: userID, filters: filters)
        if let previous = entries[key] { remove(previous) }
        guard let cost = try? UniEatDates.encoder().encode(menus).count, cost <= maximumEntryBytes else { return }
        var expiry = now.addingTimeInterval(ttl)
        for menu in source {
            var changes = [menu.publishedAt, menu.validUntil]
            if let closed = menu.closedAt { changes.append(closed) }
            if let report = menu.waitNewestReportAt {
                changes += [report, report.addingTimeInterval(30 * 60)]
            }
            for change in changes where change >= now { expiry = min(expiry, change) }
        }
        // Un limite inclusivo (p. ej. evidencia de fila exactamente a los 30 min) se recalcula.
        guard expiry > now else { return }
        let node = Node(key: key, menus: menus, insertedAt: now, expiresAt: expiry)
        entries[key] = node
        promote(node)
        if entries.count > capacity, let oldest { remove(oldest) }
    }

    /// El propietario invalida al cambiar de usuario, catalogo o publicacion.
    func clear() {
        entries.removeAll()
        newest = nil
        oldest = nil
    }
    private func remove(_ node: Node) {
        detach(node)
        entries.removeValue(forKey: node.key)
    }
    private func detach(_ node: Node) {
        if let previous = node.previous { previous.next = node.next }
        else { newest = node.next }
        if let next = node.next { next.previous = node.previous }
        else { oldest = node.previous }
        node.previous = nil
        node.next = nil
    }
    private func promote(_ node: Node) {
        node.next = newest
        newest?.previous = node
        newest = node
        if oldest == nil { oldest = node }
    }
}
