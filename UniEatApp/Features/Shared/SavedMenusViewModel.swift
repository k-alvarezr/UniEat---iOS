import Combine
import Foundation
import UniEatCore

/// Presentation stays on MainActor; the shared ModelActor performs persistence on its executor.
@MainActor
final class SavedMenusViewModel: ObservableObject {
    @Published private(set) var savedMenus: [SavedMenuEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savingIDs: Set<UUID> = []
    private let session: SessionStore
    private let events: EventService
    private let content: LocalContentService?
    private var loading: Task<Void, Never>?
    let clock: ServerClock
    init(session: SessionStore, events: EventService, clock: ServerClock, content: LocalContentService? = nil) {
        self.session = session; self.events = events; self.clock = clock
        self.content = content
    }
    private func key(_ id: UUID) -> String { "unieat.saved-menus.\(id.uuidString)" }
    func accountChanged() {
        loading?.cancel(); savedMenus = []; savingIDs = []; errorMessage = nil; isLoading = false
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, legacyKey = key(userID)
        let legacy = UserDefaults.standard.data(forKey: legacyKey)
        guard let content else {
            savedMenus = LocalValues.load([SavedMenuEntry].self, key: legacyKey) ?? []
            errorMessage = "No se pudo abrir el almacenamiento local. Se conserva la copia anterior."
            return
        }
        isLoading = true
        loading = Task {
            defer { if session.matches(userID, generation: generation) { isLoading = false } }
            do {
                if let legacy {
                    try await content.migrateSavedMenus(legacy, userID: userID)
                    UserDefaults.standard.removeObject(forKey: legacyKey) // only after the actor's commit.
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
    func toggleSaved(_ menu: DailyMenu) {
        guard let userID = session.profile?.id, !savingIDs.contains(menu.id), let content else { return }
        let generation = session.generation, savedAt = clock.now, wasSaved = isSaved(menu)
        savingIDs.insert(menu.id)
        Task {
            defer { if session.matches(userID, generation: generation) { savingIDs.remove(menu.id) } }
            do {
                let rows = try await content.toggle(menu, userID: userID, savedAt: savedAt)
                guard session.matches(userID, generation: generation) else { return }
                savedMenus = rows; errorMessage = nil
                if !wasSaved { events.track("menu_save", menu: menu) }
            } catch {
                guard session.matches(userID, generation: generation) else { return }
                errorMessage = "No se pudo guardar el cambio: \(error.localizedDescription)"
            }
        }
    }
}
