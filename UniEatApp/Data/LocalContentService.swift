import Foundation
import SwiftData
import UniEatCore

/// puerta a LocalContentStore (guardados y copias del feed) desde las pantallas (#32, #34)
/// el actor se crea con Task.detached utility para que su contexto de swiftdata trabaje fuera del hilo principal
/// todas las pantallas usan el mismo actor y el mismo ModelContainer que los reportes de #33
struct LocalContentService: Sendable {
    private let worker: Task<LocalContentStore, Never>   // el actor, se espera con .value la primera vez
    private let sessions = ContentSessionGate()
    init(container: ModelContainer) {
        worker = Task.detached(priority: .utility) { LocalContentStore(modelContainer: container) }
    }
    func setSession(userID: UUID?, generation: UUID) {
        sessions.setSession(userID: userID, generation: generation)
    }
    /// menus guardados del usuario
    func savedMenus(userID: UUID) async throws -> [SavedMenuEntry] {
        try await worker.value.savedMenus(userID: userID)
    }
    /// pasa los guardados viejos de UserDefaults a swiftdata
    func migrateSavedMenus(_ data: Data, userID: UUID) async throws {
        try await worker.value.migrateSavedMenus(data, userID: userID)
    }
    /// guarda o quita un menu y devuelve la lista ya actualizada
    func toggle(_ menu: DailyMenu, userID: UUID, savedAt: Date) async throws -> [SavedMenuEntry] {
        try await worker.value.toggle(menu, userID: userID, savedAt: savedAt)
    }
    /// guarda la copia del feed de unos filtros, o el catalogo completo si isCatalog
    func saveFeed(_ snapshot: CachedFeedSnapshot, isCatalog: Bool = false, generation: UUID? = nil) async throws {
        let permit = sessions.permit(userID: snapshot.userId, generation: generation)
        try permit.check()
        try await worker.value.saveFeed(snapshot, isCatalog: isCatalog, permit: permit)
    }
    /// La purga pasa por el mismo actor que guarda: primero termina lo que ya escribía,
    /// después borra, y los permisos revocados impiden que reaparezcan copias antiguas.
    func forget(userID: UUID, generation: UUID) async throws {
        sessions.revoke(generation)
        try await worker.value.forget(userID: userID)
    }
    /// lee la copia del feed de esos filtros, o el catalogo, nil si no hay
    func feed(userID: UUID, filters: FeedFilters, catalog: Bool = false) async throws -> CachedFeedSnapshot? {
        try await worker.value.feed(userID: userID, filters: filters, catalog: catalog)
    }
}
