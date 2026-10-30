import Combine
import Foundation
import UniEatCore

/// Identidad de una exposicion, no de la tarjeta. Copia -> vivo, nueva sesion/version o
/// nueva evidencia pueden producir una exposicion elegible sin reconstruir la lista.
struct FeedExposureKey: Hashable {
    let generation: UUID
    let sessionID: UUID
    let publicationID: UUID
    let version: Int
    let live: Bool
    let assignmentID: UUID?
    let variant: String?
    let indicatorAvailable: Bool
    let indicatorShown: Bool
}

/// Hoy, filtros y recomendacion comparten este resultado. Memoria (30 s), snapshots
/// de SwiftData y catalogo tienen propositos distintos; refrescar no vuelve a leerlos todos.
@MainActor
final class FeedViewModel: FeatureViewModel {
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var locationMenus: [DailyMenu] = []
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCachedFeed = false
    @Published private(set) var hasSnapshot = false
    @Published private(set) var loadError: String?
    @Published private(set) var cacheWarning: String?
    private let api: APIRequesting
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    private let events: EventService
    private let content: LocalContentService?
    private let memory: FeedMemoryCache
    private let offlineFilters = OfflineFilterCache()
    private var requestID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogRequestID = UUID()
    private var appliedUserID: UUID?
    private var appliedFilters: FeedFilters?
    private var catalog: CachedFeedSnapshot?
    private var didReadCatalog = false
    private var catalogInvalidated = false
    private let catalogTTL: TimeInterval = 30   // misma política; ahora también usa la fecha persistida
    var onServiceAvailable: (() -> Void)?
    var onMenusLoaded: (([DailyMenu]) -> Void)?
    var prepareContext: (() async -> Void)?

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
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: clock.now) } }
    var isOffline: Bool { connectivity.isOffline }
    var isAdmin: Bool { session.isAdmin }

    func exposureKey(for menu: DailyMenu) -> FeedExposureKey {
        let metadata = events.metadataProvider?(menu)
        return FeedExposureKey(generation: session.generation, sessionID: events.sessionID,
            publicationID: menu.id, version: menu.version, live: !isShowingCachedFeed && !isOffline,
            assignmentID: metadata?.assignmentId, variant: metadata?.variant,
            indicatorAvailable: metadata?.indicatorAvailable ?? false,
            indicatorShown: metadata?.indicatorShown ?? false)
    }

    func accountChanged() {
        refreshTask?.cancel()
        catalogTask?.cancel()
        catalogTask = nil
        catalogRequestID = UUID()
        requestID = UUID()
        memory.clear()
        offlineFilters.clear()
        appliedUserID = nil
        appliedFilters = nil
        catalog = nil
        didReadCatalog = false
        catalogInvalidated = false
        menus = []
        locationMenus = []
        isLoading = false
        loadError = nil
        cacheWarning = nil
        isShowingCachedFeed = false
        hasSnapshot = false
        guard session.profile != nil else { return }
        filters = UserDefaultsStore.load(FeedFilters.self, key: "unieat.filters") ?? FeedFilters()
        refreshTask = Task { await refresh() }
    }
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        UserDefaultsStore.save(newFilters, key: "unieat.filters")
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    /// Una publicacion/edicion/cierre confirmado invalida la memoria y el catalogo, sin
    /// borrar la copia durable que aun puede servir si se pierde la red durante la recarga.
    func invalidateAfterPublicationChange() {
        offlineFilters.clear()
        memory.clear()
        catalogInvalidated = true
        catalogTask?.cancel()
        catalogTask = nil
        catalogRequestID = UUID()
    }

    private func hasCompatibleSnapshot(userID: UUID, filters: FeedFilters) -> Bool {
        hasSnapshot && appliedUserID == userID && appliedFilters == filters
    }

    func refresh(force: Bool = false) async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = filters, id = UUID()
        requestID = id
        isLoading = true
        loadError = nil
        cacheWarning = nil
        defer { if requestID == id { isLoading = false } }
        if !force, !connectivity.isOffline, let cached = memory.value(userID: userID, filters: requested) {
            show(cached, stored: false)
            return
        }
        var readCache = false
        if !hasCompatibleSnapshot(userID: userID, filters: requested) {
            await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
            readCache = true
        }
        guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
        if !connectivity.isConnected {
            if hasSnapshot { isShowingCachedFeed = true }
            loadError = APIFailure.offline.message
            return
        }
        do {
            await prepareContext?()
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            let response: FeedResponse = try await api.get("feed", query: requested.queryItems)
            try Task.checkCancellation()
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            clock.synchronize(response.serverNow ?? response.fetchedAt)
            let snapshot = CachedFeedSnapshot(userId: userID, filters: requested, response: response)
            // La respuesta valida aparece antes del I/O. Un error de guardado no la esconde.
            show(snapshot, stored: false)
            memory.insert(snapshot)
            connectivity.serverUnreachable = false
            onServiceAvailable?()
            onMenusLoaded?(response.menus)
            if requested.queryItems.isEmpty {
                rememberCatalog(snapshot)
            } else {
                refreshCatalog(userID: userID, generation: generation)
            }
            if let content {
                do {
                    // Un feed sin filtros ya es el catalogo: no se duplica su peticion ni su JSON en disco.
                    try await content.saveFeed(snapshot, isCatalog: requested.queryItems.isEmpty, generation: generation)
                } catch {
                    if session.matches(userID, generation: generation), requestID == id {
                        cacheWarning = "El feed se cargó, pero no se pudo guardar su copia."
                    }
                }
            }
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id, requested == filters else { return }
            if (error as? APIFailure)?.code == "OFFLINE" { connectivity.serviceResponded(false) }
            loadError = error.localizedDescription
            if hasCompatibleSnapshot(userID: userID, filters: requested) {
                isShowingCachedFeed = true
            } else if !readCache {
                await loadCachedFeed(userID: userID, generation: generation, request: id, requested: requested)
            }
        }
    }

    private func show(_ snapshot: CachedFeedSnapshot, stored: Bool) {
        if menus != snapshot.response.menus { menus = snapshot.response.menus }
        if fetchedAt != snapshot.response.fetchedAt { fetchedAt = snapshot.response.fetchedAt }
        if isShowingCachedFeed != stored { isShowingCachedFeed = stored }
        if !hasSnapshot { hasSnapshot = true }
        appliedUserID = snapshot.userId
        appliedFilters = snapshot.filters
        if locationMenus.isEmpty { locationMenus = menus }
    }

    private func rememberCatalog(_ snapshot: CachedFeedSnapshot) {
        offlineFilters.clear()
        catalog = snapshot
        didReadCatalog = true
        catalogInvalidated = false
        if locationMenus != snapshot.response.menus { locationMenus = snapshot.response.menus }
    }

    /// La primera apertura recupera disco; las siguientes conservan el resultado compatible.
    /// El catalogo se lee una vez por cuenta y se reutiliza al cambiar filtros sin red.
    private func loadCachedFeed(userID: UUID, generation: UUID, request: UUID, requested: FeedFilters) async {
        var snapshot: CachedFeedSnapshot?
        do {
            if let content {
                if requested.queryItems.isEmpty {
                    if let catalog { snapshot = catalog }
                    else { snapshot = try await content.feed(userID: userID, filters: requested, catalog: true) }
                    // La version anterior guardaba tambien el feed sin filtros bajo su llave exacta.
                    if snapshot == nil { snapshot = try await content.feed(userID: userID, filters: requested) }
                } else {
                    snapshot = try await content.feed(userID: userID, filters: requested)
                }
                guard session.matches(userID, generation: generation), requestID == request, requested == filters else { return }
                if let snapshot { show(snapshot, stored: true) }
                if !didReadCatalog {
                    let storedCatalog: CachedFeedSnapshot?
                    if requested.queryItems.isEmpty { storedCatalog = snapshot }
                    else { storedCatalog = try await content.feed(userID: userID, filters: requested, catalog: true) }
                    guard session.matches(userID, generation: generation), requestID == request, requested == filters else { return }
                    catalog = storedCatalog
                    didReadCatalog = true
                    offlineFilters.clear()
                }
            }
        } catch {
            if session.matches(userID, generation: generation), requestID == request {
                cacheWarning = "No se pudo leer la copia local del feed."
            }
        }
        guard session.matches(userID, generation: generation), requestID == request, requested == filters else { return }
        if let catalog {
            if locationMenus != catalog.response.menus { locationMenus = catalog.response.menus }
            if snapshot == nil {
                let now = clock.now
                let filtered: [DailyMenu]
                if let cached = offlineFilters.value(userID: userID, filters: requested, at: now) {
                    filtered = cached
                } else {
                    filtered = OfflineMenuFiltering.filter(catalog.response.menus, filters: requested, at: now)
                    offlineFilters.insert(filtered, source: catalog.response.menus, userID: userID, filters: requested, at: now)
                }
                snapshot = CachedFeedSnapshot(userId: userID, filters: requested,
                    response: FeedResponse(fetchedAt: catalog.response.fetchedAt,
                        menus: filtered))
            }
        }
        if let snapshot { show(snapshot, stored: true) }
        else {
            menus = []
            hasSnapshot = false
            isShowingCachedFeed = false
            appliedUserID = nil
            appliedFilters = nil
        }
    }

    private func refreshCatalog(userID: UUID, generation: UUID) {
        guard let content, catalogTask == nil else { return }
        let catalogID = UUID()
        catalogRequestID = catalogID
        catalogTask = Task {
            defer {
                if session.matches(userID, generation: generation), catalogRequestID == catalogID { catalogTask = nil }
            }
            do {
                if !didReadCatalog {
                    let stored = try await content.feed(userID: userID, filters: Self.allFilters, catalog: true)
                    guard session.matches(userID, generation: generation), catalogRequestID == catalogID, !Task.isCancelled else { return }
                    catalog = stored
                    didReadCatalog = true
                    offlineFilters.clear()
                    if let stored, locationMenus != stored.response.menus { locationMenus = stored.response.menus }
                }
                if let catalog, !catalogInvalidated {
                    let age = clock.now.timeIntervalSince(catalog.response.fetchedAt)
                    if age >= 0, age < catalogTTL { return }
                }
                let response: FeedResponse = try await api.get("feed", query: [.init(name: "refresh", value: "auto")])
                guard session.matches(userID, generation: generation), catalogRequestID == catalogID, !Task.isCancelled else { return }
                let snapshot = CachedFeedSnapshot(userId: userID, filters: Self.allFilters, response: response)
                try await content.saveFeed(snapshot, isCatalog: true, generation: generation)
                guard session.matches(userID, generation: generation), catalogRequestID == catalogID, !Task.isCancelled else { return }
                rememberCatalog(snapshot)
                // Solo se precargan fotos del resultado mostrado, nunca de este calentamiento de catalogo.
            } catch {
                // El calentamiento opcional no oculta una respuesta valida del feed.
            }
        }
    }
    private static var allFilters: FeedFilters {
        FeedFilters(budgetCop: nil, availableMinutes: nil, diet: nil, area: nil, paymentMethod: nil)
    }
    func track(_ kind: String, menu: DailyMenu) { events.track(kind, menu: menu) }
    /// llave de la copia vieja del feed en UserDefaults (antes del #45), ya no se lee, solo se borra al cerrar sesion
    static let cacheKey = "unieat.remote.feed-cache.v1"
}
