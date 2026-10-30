import Foundation
import UniEatCore

/// NSCache evicts on memory pressure; the explicit TTL is independent of eviction.
@MainActor
final class FeedMemoryCache {
    private final class Entry {
        let snapshot: CachedFeedSnapshot
        let insertedAt: Date
        init(_ snapshot: CachedFeedSnapshot, at: Date) { self.snapshot = snapshot; insertedAt = at }
    }
    private let cache = NSCache<NSString, Entry>()
    private let now: () -> Date
    let ttl: TimeInterval = 30
    init(now: @escaping () -> Date = { .now }) {
        self.now = now
        cache.countLimit = 12 // a small collection of recent filter combinations.
        cache.totalCostLimit = 4 * 1024 * 1024 // encoded JSON bytes, not an invented per-item weight.
    }
    func value(userID: UUID, filters: FeedFilters) -> CachedFeedSnapshot? {
        let key = FeedCacheKey.make(userID: userID, filters: filters) as NSString
        guard let entry = cache.object(forKey: key) else { return nil }
        guard now().timeIntervalSince(entry.insertedAt) >= 0, now().timeIntervalSince(entry.insertedAt) < ttl else {
            cache.removeObject(forKey: key); return nil
        }
        return entry.snapshot
    }
    func insert(_ snapshot: CachedFeedSnapshot) {
        let key = FeedCacheKey.make(userID: snapshot.userId, filters: snapshot.filters) as NSString
        let cost = (try? UniEatDates.encoder().encode(snapshot).count) ?? 0
        cache.setObject(Entry(snapshot, at: now()), forKey: key, cost: cost)
    }
    func clear() { cache.removeAllObjects() }
}
