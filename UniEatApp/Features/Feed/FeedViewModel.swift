import Combine
import Foundation
import UniEatCore

/// ultimo feed que se bajo, sin internet solo se usa si es del mismo usuario y con los mismos filtros
private struct CachedFeed: Codable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
    // hora del server cuando se bajo, para la vigencia sin red
    var timeReference: ServerTimeReference?
}

/// el feed sale del AppStore viejo a su propio viewmodel BQ-03
/// hoy, filtros y elige por mi leen este mismo resultado, asi no hay dos copias distintas del feed
@MainActor
final class FeedViewModel: FeatureViewModel {
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    // hay una carga en camino
    @Published private(set) var isLoading = false
    // true si lo que se ve es la copia guardada y no la respuesta del server
    @Published private(set) var isShowingCachedFeed = false
    // error de la ultima carga, la pantalla muestra reintentar
    @Published private(set) var loadError: String?
    private let api: APIRequesting
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    private let events: EventService
    // id de la ultima carga, una respuesta vieja no pisa una nueva
    private var requestID = UUID()
    // carga en camino, se cancela si cambian los filtros o la cuenta
    private var refreshTask: Task<Void, Never>?
    // lo pone AppStore, cuando el feed carga bien se mandan las colas
    var onServiceAvailable: (() -> Void)?
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         clock: ServerClock, events: EventService) {
        self.api = api; self.session = session; self.connectivity = connectivity
        self.clock = clock; self.events = events
        super.init(); observe(connectivity); observe(clock)
    }
    /// menus en el orden del server quitando los vencidos, aunque vengan de la copia
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: clock.now) } }
    var isOffline: Bool { connectivity.isOffline }
    var isAdmin: Bool { session.isAdmin }
    /// al cambiar de cuenta se limpia, se cargan los filtros y la copia de ese usuario y se pide el feed
    func accountChanged() {
        refreshTask?.cancel(); requestID = UUID()
        menus = []; isLoading = false; loadError = nil; isShowingCachedFeed = false
        guard session.profile != nil else { return }
        filters = LocalValues.load(FeedFilters.self, key: "unieat.filters") ?? FeedFilters()
        loadCachedFeed()
        refreshTask = Task { await refresh() }
    }
    /// guarda los filtros nuevos y pide el feed con ellos, cancela la carga anterior
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        LocalValues.save(newFilters, key: "unieat.filters")
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }
    /// pide el feed al server y guarda la copia para sin internet, si falla se usa la copia
    /// si cambio la cuenta, los filtros o arranco otra carga mientras tanto se bota la respuesta
    func refresh() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = filters, id = UUID()
        requestID = id; isLoading = true; loadError = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let feed: FeedResponse = try await api.get("feed", query: requested.queryItems)
            try Task.checkCancellation()
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            clock.synchronize(feed.serverNow ?? feed.fetchedAt)
            menus = feed.menus; fetchedAt = feed.fetchedAt
            connectivity.serverUnreachable = false; isShowingCachedFeed = false
            LocalValues.save(CachedFeed(userId: userID, filters: requested, response: feed,
                                        timeReference: clock.snapshot()), key: "unieat.remote.feed-cache.v1")
            onServiceAvailable?()
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            connectivity.serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadError = error.localizedDescription
            loadCachedFeed()
        }
    }
    /// usa la copia solo si es del mismo usuario y con los mismos filtros, si no deja la lista vacia
    private func loadCachedFeed() {
        guard let cached = LocalValues.load(CachedFeed.self, key: "unieat.remote.feed-cache.v1"),
              cached.userId == session.profile?.id, cached.filters == filters else {
            menus = []; isShowingCachedFeed = false; return
        }
        if let reference = cached.timeReference { clock.restore(reference) }
        menus = cached.response.menus; fetchedAt = cached.response.fetchedAt; isShowingCachedFeed = true
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
}
