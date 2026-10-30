import Combine
import Foundation
import UniEatCore

/// menu que el usuario guardo en el celular, se guarda por cuenta
struct SavedMenu: Codable, Identifiable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

/// los guardados salen del AppStore viejo a su viewmodel
/// siguen en UserDefaults con el mismo formato hasta que #34 los pase a swiftdata
@MainActor
final class SavedMenusViewModel: ObservableObject {
    @Published private(set) var savedMenus: [SavedMenu] = []
    private let session: SessionStore
    private let events: EventService
    let clock: ServerClock
    init(session: SessionStore, events: EventService, clock: ServerClock) {
        self.session = session; self.events = events; self.clock = clock
    }
    // llave por usuario
    private func key(_ id: UUID) -> String { "unieat.saved-menus.\(id.uuidString)" }
    /// al cambiar de cuenta se cargan los guardados de ese usuario
    func accountChanged() {
        savedMenus = session.profile.map { LocalValues.load([SavedMenu].self, key: key($0.id)) ?? [] } ?? []
    }
    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }
    /// guarda o quita el menu, al guardar cuenta el evento menu_save
    func toggleSaved(_ menu: DailyMenu) {
        guard let userID = session.profile?.id else { return }
        if isSaved(menu) { savedMenus.removeAll { $0.id == menu.id } }
        else { savedMenus.insert(SavedMenu(menu: menu, savedAt: clock.now), at: 0); events.track("menu_save", menu: menu) }
        LocalValues.save(savedMenus, key: key(userID))
    }
}
