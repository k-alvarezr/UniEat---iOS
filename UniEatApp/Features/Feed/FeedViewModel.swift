import Combine
import Foundation
import UniEatCore

/// feed compartido BQ-03: hoy, filtros y elige por mi leen este mismo resultado, asi no hay dos copias distintas
/// tiene tres niveles de copia: memoria por 30 s, copia por filtros en swiftdata y el catalogo completo para sin red
@MainActor
final class FeedViewModel: FeatureViewModel {
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var locationMenus: [DailyMenu] = []   // catalogo completo, para sugerir zona y filtrar sin red
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    // hay una carga en camino
    @Published private(set) var isLoading = false
    // true si lo que se ve es la copia guardada y no la respuesta del server
    @Published private(set) var isShowingCachedFeed = false
    @Published private(set) var hasSnapshot = false            // hay alguna copia descargada para mostrar su fecha
    @Published private(set) var loadError: String?
    @Published private(set) var cacheWarning: String?          // la copia no se pudo leer o guardar
    @Published private(set) var contentRevision = UUID()       // cambia para volver a armar las tarjetas
    private let api: APIRequesting
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    private let events: EventService
    private let content: LocalContentService?   // swiftdata en segundo plano, nil si la base no abrio
    private let memory: FeedMemoryCache         // copia en memoria por 30 s
    private var requestID = UUID()
    // carga en camino, se cancela si cambian los filtros o la cuenta
    private var refreshTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?   // descarga del catalogo en camino
    private var catalogAt: Date?                  // cuando se bajo el catalogo por ultima vez
    var onServiceAvailable: (() -> Void)?          // AppStore manda las colas cuando el feed carga bien
    var onMenusLoaded: (([DailyMenu]) -> Void)?    // AppStore baja las fotos
    var prepareContext: (() async -> Void)?        // piloto BQ-08: asigna la variante antes de pedir el feed
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         clock: ServerClock, events: EventService, content: LocalContentService? = nil,
         memory: FeedMemoryCache? = nil) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.clock = clock
        self.events = events
        self.content = content
        self.memory = memory ?? FeedMemoryCache()
        super.init()
        observe(connectivity)
    }
    /// menus en el orden del server quitando los vencidos, aunque vengan de la copia
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: clock.now) } }
    var isOffline: Bool { connectivity.isOffline }
    var isAdmin: Bool { session.isAdmin }
    /// al cambiar de cuenta se limpia, se cargan los filtros y la copia de ese usuario y se pide el feed
    func accountChanged() {
        refreshTask?.cancel()
        catalogTask?.cancel()
        catalogTask = nil
        catalogAt = nil
        requestID = UUID()
        memory.clear()
        menus = []
        locationMenus = []
        isLoading = false
        loadError = nil
        cacheWarning = nil
        isShowingCachedFeed = false
        hasSnapshot = false
        guard session.profile != nil else { return }
        filters = LocalValues.load(FeedFilters.self, key: "unieat.filters") ?? FeedFilters()
        refreshTask = Task { await refresh() }
    }
    /// guarda los filtros nuevos y pide el feed con ellos, cancela la carga anterior
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        LocalValues.save(newFilters, key: "unieat.filters")
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }
    func refresh(force: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = filters, id = UUID()
        requestID = id
        isLoading = true
        loadError = nil
        cacheWarning = nil
        defer { if requestID == id { isLoading = false } }
        // 1. si esta en memoria y tiene menos de 30 s no se pide otra vez (force lo salta)
        if !force, !connectivity.isOffline, let cached = memory.value(userID: userID, filters: requested) {
            apply(cached, stored: false)
            return
        }
        // 2. sin red: la copia guardada y el aviso de sin conexion
        if !connectivity.isConnected {
            await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
            if session.matches(userID, generation: generation), requestID == id { loadError = APIFailure.offline.message }
            return
        }
        // 3. con red: primero la copia (asi se ve algo al abrir) y despues el server
        await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
        guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
        do {
            await prepareContext?()
            guard session.matches(userID, generation: generation), requestID == id else { return }
            let feed: FeedResponse = try await api.get("feed", query: requested.queryItems)
            try Task.checkCancellation()
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            clock.synchronize(feed.serverNow ?? feed.fetchedAt)
            // se guarda en memoria y en swiftdata, si no se pudo guardar se avisa pero el feed se muestra igual
            let snapshot = CachedFeedSnapshot(userId: userID, filters: requested, response: feed, timeReference: clock.snapshot())
            memory.insert(snapshot)
            if let content {
                do {
                    try await content.saveFeed(snapshot, generation: generation)
                } catch {
                    if session.matches(userID, generation: generation), requestID == id {
                        cacheWarning = "El feed se cargó, pero no se pudo guardar su copia."
                    }
                }
            }
            guard session.matches(userID, generation: generation), requestID == id else { return }
            apply(snapshot, stored: false)
            connectivity.serverUnreachable = false
            onServiceAvailable?()
            onMenusLoaded?(feed.menus)
            refreshCatalog(userID: userID, generation: generation)
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            connectivity.serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadError = error.localizedDescription
            await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
        }
    }
    /// pone en pantalla una copia, stored en true es que viene guardada y no del server
    private func apply(_ snapshot: CachedFeedSnapshot, stored: Bool) {
        if let reference = snapshot.timeReference { clock.restore(reference) }
        menus = snapshot.response.menus
        fetchedAt = snapshot.response.fetchedAt
        isShowingCachedFeed = stored
        hasSnapshot = true
        contentRevision = UUID()   // vuelve a armar las tarjetas para que el piloto registre la vista
        if locationMenus.isEmpty { locationMenus = menus }
    }
    /// busca una copia guardada para estos filtros: primero la de swiftdata, si no la vieja de UserDefaults
    /// y si nunca se pidieron estos filtros, filtra el catalogo completo en el celular
    private func loadCachedFeed(userID: UUID, generation: UUID, request: UUID, requested: FeedFilters) async {
        var snapshot: CachedFeedSnapshot?
        var catalog: CachedFeedSnapshot?
        if let content {
            do {
                snapshot = try await content.feed(userID: userID, filters: requested)
                catalog = try await content.feed(userID: userID, filters: requested, catalog: true)
            } catch {
                if session.matches(userID, generation: generation), requestID == request {
                    cacheWarning = "No se pudo leer la copia local del feed."
                }
            }
        }
        if snapshot == nil, let old = LocalValues.load(CachedFeedSnapshot.self, key: Self.cacheKey),
           old.userId == userID, old.filters == requested {
            snapshot = old
        }
        guard session.matches(userID, generation: generation), requestID == request, requested == filters else { return }
        if let catalog {
            if let reference = catalog.timeReference { clock.restore(reference) }
            locationMenus = catalog.response.menus
            if snapshot == nil {
                let filtered = OfflineMenuFiltering.filter(catalog.response.menus, filters: requested, at: clock.now)
                snapshot = CachedFeedSnapshot(userId: userID, filters: requested,
                    response: FeedResponse(fetchedAt: catalog.response.fetchedAt, menus: filtered), timeReference: catalog.timeReference)
            }
        }
        if let snapshot {
            apply(snapshot, stored: true)
        } else {
            menus = []
            isShowingCachedFeed = false
            hasSnapshot = false
        }
    }
    /// baja el catalogo completo sin filtros para poder filtrar sin red, maximo cada 30 s
    /// va con refresh=auto para que el server no lo cuente como una consulta del estudiante
    private func refreshCatalog(userID: UUID, generation: UUID) {
        guard let content, catalogTask == nil,
              catalogAt == nil || clock.now.timeIntervalSince(catalogAt!) > 30 else { return }
        catalogTask = Task {
            defer { if session.matches(userID, generation: generation) { catalogTask = nil } }
            do {
                let response: FeedResponse = try await api.get("feed", query: [.init(name: "refresh", value: "auto")])
                guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
                let all = FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
                try await content.saveFeed(CachedFeedSnapshot(userId: userID, filters: all, response: response, timeReference: clock.snapshot()),
                    isCatalog: true, generation: generation)
                guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
                locationMenus = response.menus
                catalogAt = clock.now
                onMenusLoaded?(response.menus)
            } catch {
                // es opcional, si falla el feed en vivo se sigue viendo igual
            }
        }
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
    /// llave de la copia del feed en UserDefaults, AppStore la borra al cerrar sesion
    static let cacheKey = "unieat.remote.feed-cache.v1"
}
