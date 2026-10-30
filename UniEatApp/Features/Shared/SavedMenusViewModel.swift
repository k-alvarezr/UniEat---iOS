import Combine
import Foundation
import UniEatCore

struct SavedMenu: Codable, Identifiable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

/// Keeps the existing UserDefaults format until issue #34 migrates it to the shared container.
@MainActor
final class SavedMenusViewModel: ObservableObject {
    @Published private(set) var savedMenus: [SavedMenu] = []
    private let session: SessionStore
    private let events: EventService
    let clock: ServerClock
    init(session: SessionStore, events: EventService, clock: ServerClock) {
        self.session = session; self.events = events; self.clock = clock
    }
    private func key(_ id: UUID) -> String { "unieat.saved-menus.\(id.uuidString)" }
    func accountChanged() {
        savedMenus = session.profile.map { LocalValues.load([SavedMenu].self, key: key($0.id)) ?? [] } ?? []
    }
    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }
    func toggleSaved(_ menu: DailyMenu) {
        guard let userID = session.profile?.id else { return }
        if isSaved(menu) { savedMenus.removeAll { $0.id == menu.id } }
        else { savedMenus.insert(SavedMenu(menu: menu, savedAt: clock.now), at: 0); events.track("menu_save", menu: menu) }
        LocalValues.save(savedMenus, key: key(userID))
    }
}
