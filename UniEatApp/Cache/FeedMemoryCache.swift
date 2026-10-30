import Foundation
import UniEatCore

/// copia del feed en memoria: si se cambia de filtro y se vuelve en menos de 30 s no se pide otra vez
/// NSCache bota entradas solo si el celular se queda sin memoria, el vencimiento de 30 s se revisa aparte
@MainActor
final class FeedMemoryCache {
    // lo que se guarda: la copia y cuando se guardo, para saber si ya vencio
    private final class Entry {
        let snapshot: CachedFeedSnapshot
        let insertedAt: Date
        init(_ snapshot: CachedFeedSnapshot, at: Date) {
            self.snapshot = snapshot
            insertedAt = at
        }
    }
    private let cache = NSCache<NSString, Entry>()   // llave = usuario + filtros
    private let now: () -> Date                      // se inyecta para las pruebas
    let ttl: TimeInterval = 30                       // segundos que dura una copia en memoria
    init(now: @escaping () -> Date = { .now }) {
        self.now = now
        cache.countLimit = 12                       // pocas combinaciones de filtros recientes
        cache.totalCostLimit = 4 * 1024 * 1024      // 4 MB, el costo de cada entrada son los bytes de su json
    }
    /// la copia de esos filtros si tiene menos de 30 s, si ya vencio se borra y devuelve nil
    func value(userID: UUID, filters: FeedFilters) -> CachedFeedSnapshot? {
        let key = FeedCacheKey.make(userID: userID, filters: filters) as NSString
        guard let entry = cache.object(forKey: key) else { return nil }
        let age = now().timeIntervalSince(entry.insertedAt)
        guard age >= 0, age < ttl else {
            cache.removeObject(forKey: key)
            return nil
        }
        return entry.snapshot
    }
    /// guarda la copia con su tamaño en bytes como costo
    func insert(_ snapshot: CachedFeedSnapshot) {
        let key = FeedCacheKey.make(userID: snapshot.userId, filters: snapshot.filters) as NSString
        let cost = (try? UniEatDates.encoder().encode(snapshot).count) ?? 0
        cache.setObject(Entry(snapshot, at: now()), forKey: key, cost: cost)
    }
    /// al cambiar de cuenta se bota todo
    func clear() { cache.removeAllObjects() }
}
