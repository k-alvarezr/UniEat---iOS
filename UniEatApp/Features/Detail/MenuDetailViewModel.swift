import Combine
import Foundation
import UniEatCore

/// estado del detalle BQ-04 que antes estaba en MenuDetailView con @State
/// uno por pantalla de detalle, lo crea AppContainer.makeDetail
@MainActor
final class MenuDetailViewModel: FeatureViewModel {
    @Published private(set) var detail: MenuDetail?
    @Published private(set) var loadError: APIFailure?
    @Published private(set) var isLoading = false
    @Published private(set) var cacheWarning: String?
    let initialMenu: DailyMenu
    let clock: ServerClock
    private let service: MenuDetailService
    private let session: SessionStore
    private let events: EventService
    private let saved: SavedMenusViewModel
    private let connectivity: ConnectivityService
    private let pilot: WaitIndicatorPilot?
    private let initialFetchedAt: Date?
    private var requestID = UUID()
    init(menu: DailyMenu, service: MenuDetailService, session: SessionStore, events: EventService,
         saved: SavedMenusViewModel, connectivity: ConnectivityService, clock: ServerClock, pilot: WaitIndicatorPilot? = nil,
         initialFetchedAt: Date? = nil) {
        initialMenu = menu
        self.service = service
        self.session = session
        self.events = events
        self.saved = saved
        self.connectivity = connectivity
        self.clock = clock
        self.pilot = pilot
        self.initialFetchedAt = initialFetchedAt
        super.init()
        observe(saved)
        observe(session)
        observe(connectivity)
        observe(events)
        // el piloto de la BQ-08 cambia si se muestra el indicador de fila
        if let pilot { observe(pilot) }
    }
    /// la version del server si ya llego, si no la de la tarjeta
    var menu: DailyMenu { detail?.menu ?? initialMenu }
    /// el server dijo 410 vencido o cerrado o 404
    var isGone: Bool { ["GONE", "NOT_FOUND"].contains(loadError?.code ?? "") }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var isOffline: Bool { connectivity.isOffline }
    var isConnected: Bool { connectivity.isConnected }
    var showsWaitIndicator: Bool { pilot?.showsWaitIndicator ?? true }
    var fetchedAt: Date { detail?.serverNow ?? initialFetchedAt ?? menu.publishedAt }
    func isOpen() -> Bool {
        !isGone && (detail?.status(at: clock.now).acceptsActions ?? menu.isActive(at: clock.now))
    }
    func statusLabel() -> String {
        if isGone { return "No disponible" }
        return detail?.status(at: clock.now).label ?? (menu.isActive(at: clock.now) ? "Vigente" : "Vencido")
    }
    /// recarga antes de abrir la hoja para que el reporte quede con la version actual
    func canReport() async -> Bool {
        await load(automatic: true)
        return isOpen()
    }
    /// elegir este menu, cuenta una vez por version en la sesion
    func choose() {
        guard isOpen() else { return }
        events.track("selection", menu: menu)
    }
    /// marcar que llego, solo si antes lo eligio
    func arrive() {
        guard isOpen(), wasChosen(menu) else { return }
        events.track("arrival", menu: menu)
    }
    /// carga el detalle, si automatic es true el server no lo cuenta en metricas
    /// si cambio la sesion o arranco otra carga se bota el resultado y una cancelacion no se muestra como error
    func load(automatic: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        let expected = session.generation, id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        // Sin ruta de red se consulta solo el archivo. No se espera un timeout para navegar o reportar.
        if !connectivity.isConnected {
            let copy = await service.savedCopy(initialMenu, generation: expected)
            guard session.matches(userID, generation: expected), requestID == id else { return }
            if detail == nil { detail = copy }
            loadError = .offline
            return
        }
        // copia del disco y server en paralelo con async let (#31), la copia se muestra mientras llega el server
        async let cached = service.savedCopy(initialMenu, generation: expected)
        async let fresh = service.fetch(initialMenu, automatic: automatic, generation: expected)
        if let copy = await cached, session.matches(userID, generation: expected), requestID == id, detail == nil {
            detail = copy
        }
        do {
            let value = try await fresh
            guard session.matches(userID, generation: expected), requestID == id else { return }
            detail = value.detail
            cacheWarning = value.cacheWarning
            loadError = nil
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: expected), requestID == id else { return }
            loadError = (error as? APIFailure) ?? .unexpected
        }
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
    func isSaved(_ menu: DailyMenu) -> Bool { saved.isSaved(menu) }
    func toggleSaved(_ menu: DailyMenu) { saved.toggleSaved(menu) }
    func wasChosen(_ menu: DailyMenu) -> Bool { events.hasCounted("selection", menu: menu) }
    func hasArrived(_ menu: DailyMenu) -> Bool { events.hasCounted("arrival", menu: menu) }
}
