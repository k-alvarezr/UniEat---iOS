import Foundation
import SwiftData
import UniEatCore

/// Construct the ModelActor off MainActor so its ModelContext uses a background executor.
/// The task is shared: every feature reaches the same actor and the same ModelContainer.
struct LocalContentService: Sendable {
    private let worker: Task<LocalContentStore, Never>
    init(container: ModelContainer) {
        worker = Task.detached(priority: .utility) { LocalContentStore(modelContainer: container) }
    }
    func savedMenus(userID: UUID) async throws -> [SavedMenuEntry] { try await worker.value.savedMenus(userID: userID) }
    func migrateSavedMenus(_ data: Data, userID: UUID) async throws { try await worker.value.migrateSavedMenus(data, userID: userID) }
    func toggle(_ menu: DailyMenu, userID: UUID, savedAt: Date) async throws -> [SavedMenuEntry] {
        try await worker.value.toggle(menu, userID: userID, savedAt: savedAt)
    }
    func saveFeed(_ snapshot: CachedFeedSnapshot, isCatalog: Bool = false) async throws {
        try await worker.value.saveFeed(snapshot, isCatalog: isCatalog)
    }
    func feed(userID: UUID, filters: FeedFilters, catalog: Bool = false) async throws -> CachedFeedSnapshot? {
        try await worker.value.feed(userID: userID, filters: filters, catalog: catalog)
    }
}
