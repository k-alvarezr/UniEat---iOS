import Combine
import Foundation
import UniEatCore

@MainActor
final class MenuDetailViewModel: FeatureViewModel {
    @Published private(set) var detail: MenuDetail?
    @Published private(set) var loadError: APIFailure?
    @Published private(set) var isLoading = false
    let initialMenu: DailyMenu
    let clock: ServerClock
    private let service: MenuDetailService
    private let session: SessionStore
    private let events: EventService
    private let saved: SavedMenusViewModel
    private let connectivity: ConnectivityService
    private var requestID = UUID()
    init(menu: DailyMenu, service: MenuDetailService, session: SessionStore, events: EventService,
         saved: SavedMenusViewModel, connectivity: ConnectivityService, clock: ServerClock) {
        initialMenu = menu; self.service = service; self.session = session; self.events = events
        self.saved = saved; self.connectivity = connectivity; self.clock = clock
        super.init(); observe(saved); observe(session); observe(connectivity); observe(clock)
    }
    var menu: DailyMenu { detail?.menu ?? initialMenu }
    var isGone: Bool { ["GONE", "NOT_FOUND"].contains(loadError?.code ?? "") }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var isOffline: Bool { connectivity.isOffline }
    var fetchedAt: Date { detail?.serverNow ?? menu.publishedAt }
    func isOpen() -> Bool {
        !isGone && (detail?.status(at: clock.now).acceptsActions ?? menu.isActive(at: clock.now))
    }
    func statusLabel() -> String {
        if isGone { return "No disponible" }
        return detail?.status(at: clock.now).label ?? (menu.isActive(at: clock.now) ? "Vigente" : "Vencido")
    }
    func load(automatic: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        let expected = session.generation, id = UUID()
        requestID = id; isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let value = try await service.load(initialMenu, automatic: automatic)
            guard session.matches(userID, generation: expected), requestID == id else { return }
            detail = value; loadError = nil
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: expected), requestID == id else { return }
            loadError = (error as? APIFailure) ?? .unexpected
            if loadError?.code == "OFFLINE", detail == nil { detail = service.cached(initialMenu) }
        }
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
    func isSaved(_ menu: DailyMenu) -> Bool { saved.isSaved(menu) }
    func toggleSaved(_ menu: DailyMenu) { saved.toggleSaved(menu) }
    func wasChosen(_ menu: DailyMenu) -> Bool { events.hasCounted("selection", menu: menu) }
    func hasArrived(_ menu: DailyMenu) -> Bool { events.hasCounted("arrival", menu: menu) }
}
