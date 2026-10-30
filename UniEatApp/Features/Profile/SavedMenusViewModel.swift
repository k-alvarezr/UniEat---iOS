import Combine
import Foundation
import UniEatCore

/// menus guardados del usuario (#34): la pantalla vive en el hilo principal
/// y guardar o leer en swiftdata lo hace el actor compartido en segundo plano (LocalContentService)
@MainActor
final class SavedMenusViewModel: ObservableObject {
    @Published private(set) var savedMenus: [SavedMenuEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savingIDs: Set<UUID> = []   // menus que se estan guardando, el boton se desactiva
    private let session: SessionStore
    private let events: EventService
    private let content: LocalContentService?
    private var loading: Task<Void, Never>?
    let clock: ServerClock
    init(session: SessionStore, events: EventService, clock: ServerClock, content: LocalContentService? = nil) {
        self.session = session
        self.events = events
        self.clock = clock
        self.content = content
    }
    // llave por usuario
    private func key(_ id: UUID) -> String { "unieat.saved-menus.\(id.uuidString)" }
    /// al cambiar de cuenta se cargan los guardados de ese usuario
    func accountChanged() {
        loading?.cancel()
        savedMenus = []
        savingIDs = []
        errorMessage = nil
        isLoading = false
        guard let userID = session.profile?.id else { return }
        let generation = session.generation
        let legacyKey = key(userID)
        let legacy = UserDefaults.standard.data(forKey: legacyKey)
        // si la base no abrio se muestra lo que habia en UserDefaults
        guard let content else {
            savedMenus = UserDefaultsStore.load([SavedMenuEntry].self, key: legacyKey) ?? []
            errorMessage = "No se pudo abrir el almacenamiento local. Se conserva la copia anterior."
            return
        }
        isLoading = true
        loading = Task {
            defer { if session.matches(userID, generation: generation) { isLoading = false } }
            do {
                // los guardados viejos de UserDefaults pasan a swiftdata una sola vez
                // y se borran de UserDefaults solo despues de que el actor los guardo bien
                if let legacy {
                    try await content.migrateSavedMenus(legacy, userID: userID)
                    UserDefaults.standard.removeObject(forKey: legacyKey)
                }
                let rows = try await content.savedMenus(userID: userID)
                guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
                savedMenus = rows
            } catch {
                guard session.matches(userID, generation: generation) else { return }
                errorMessage = "No se pudieron leer tus guardados: \(error.localizedDescription)"
            }
        }
    }
    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }
    /// guarda o quita el menu, al guardar cuenta el evento menu_save
    func toggleSaved(_ menu: DailyMenu) {
        guard let userID = session.profile?.id, !savingIDs.contains(menu.id), let content else { return }
        let generation = session.generation
        let savedAt = clock.now
        let wasSaved = isSaved(menu)
        // mientras se guarda ese menu no se acepta otro toque sobre el mismo
        savingIDs.insert(menu.id)
        Task {
            defer { if session.matches(userID, generation: generation) { savingIDs.remove(menu.id) } }
            do {
                // swiftdata en el actor de segundo plano, devuelve la lista ya actualizada
                let rows = try await content.toggle(menu, userID: userID, savedAt: savedAt)
                guard session.matches(userID, generation: generation) else { return }
                savedMenus = rows
                errorMessage = nil
                if !wasSaved { events.track("menu_save", menu: menu) }
            } catch {
                guard session.matches(userID, generation: generation) else { return }
                errorMessage = "No se pudo guardar el cambio: \(error.localizedDescription)"
            }
        }
    }
}
