import Foundation
import Network
import SwiftUI
import UniEatCore

/// menu que el usuario guardo en el celular, se guarda por cuenta
struct SavedMenu: Codable, Identifiable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

/// ultimo feed que se bajo, sin internet solo se usa si es del mismo usuario y con los mismos filtros
private struct CachedFeed: Codable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
}

/// este es el viewmodel de toda la app, las pantallas leen de aca y le piden cosas
/// el server decide vigencia orden y permisos, aca solo se muestra lo que responde
@MainActor
final class AppStore: ObservableObject {
    // MARK: - sesion
    @Published private(set) var profile: Profile?
    @Published private(set) var memberships: [RemoteMembership] = []
    @Published private(set) var establishments: [RemoteEstablishment] = []
    @Published var authMessage: String?

    // MARK: - feed
    @Published private(set) var menus: [DailyMenu] = []
    @Published private(set) var filters = FeedFilters()
    @Published private(set) var fetchedAt = Date.now
    @Published private(set) var ownMenus: [DailyMenu] = []
    @Published private(set) var savedMenus: [SavedMenu] = []

    // MARK: - conexion
    @Published private(set) var isConnected = true
    @Published private(set) var serverUnreachable = false

    // MARK: - metricas
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]
    @Published private(set) var performanceError: String?

    private let auth = SupabaseAuthService()
    private lazy var api = APIClient(configuration: .current) { [unowned self] in
        try await self.auth.validAccessToken()
    }
    private let monitor = NWPathMonitor()
    private let sessionID = UUID()
    private var impressions: Set<UUID> = []
    private var pendingEvents: [RemoteEvent] = []
    private var isFlushing = false

    private enum Keys {
        static let filters = "unieat.filters"
        static let feedCache = "unieat.remote.feed-cache.v1"
        static let pendingEvents = "unieat.remote.pending-events.v1"
        static func savedMenus(_ userId: UUID) -> String { "unieat.saved-menus.\(userId.uuidString)" }
    }

    init() {
        filters = Self.load(FeedFilters.self, key: Keys.filters) ?? FeedFilters()
        pendingEvents = Self.load([RemoteEvent].self, key: Keys.pendingEvents) ?? []

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "unieat.connectivity"))

        Task {
            if let restored = await auth.restore() { await startSession(with: restored) }
        }
    }

    // MARK: - estado calculado

    var isOffline: Bool { !isConnected || serverUnreachable }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    /// lo de admin solo sirve con internet para no tocar datos viejos
    var isAdmin: Bool { profile?.role == "admin" && !isOffline }
    var approvedEstablishments: [RemoteEstablishment] { establishments.filter(\.approved) }

    /// menus en el orden que manda el server, quitando los vencidos aunque vengan de la copia guardada
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: .now) } }

    // MARK: - sesion

    func signIn(email: String, password: String) async throws {
        let signedIn = try await auth.signIn(email: email, password: password)
        await startSession(with: signedIn)
    }

    func signUp(email: String, password: String, name: String) async throws {
        guard let signedIn = try await auth.signUp(email: email, password: password, name: name) else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
            return
        }
        await startSession(with: signedIn)
    }

    /// el rol siempre sale de GET /me, si falla queda como estudiante
    private func startSession(with signedIn: Profile) async {
        authMessage = nil
        profile = signedIn
        savedMenus = Self.load([SavedMenu].self, key: Keys.savedMenus(signedIn.id)) ?? []
        loadCachedFeed()
        do {
            try await loadAccount()
        } catch {
            profile = Profile(id: signedIn.id, displayName: signedIn.displayName, role: "student")
        }
        await refresh()
    }

    private func loadAccount() async throws {
        let me: MeResponse = try await api.get("me")
        profile = me.profile
        memberships = me.establishments
        let mine: EstablishmentsResponse = try await api.get("establishments/mine")
        establishments = mine.establishments
    }

    func refreshAccount() async throws {
        try await loadAccount()
        await refresh()
    }

    func signOut() {
        auth.signOut()
        UserDefaults.standard.removeObject(forKey: Keys.feedCache)
        pendingEvents = []
        save(pendingEvents, key: Keys.pendingEvents)
        profile = nil
        memberships = []
        establishments = []
        menus = []
        ownMenus = []
        savedMenus = []
        impressions = []
        adminDashboard = [:]
        restaurantPerformance = [:]
        performanceError = nil
    }

    // MARK: - locales y roles

    func requestEstablishment(_ request: EstablishmentRequestBody) async throws {
        let _: EstablishmentRequestResponse = try await api.send("POST", "establishments", body: request)
        // la solicitud ya se creo, si falla recargar no queremos que parezca que fallo el envio
        try? await loadAccount()
    }

    func pendingMembershipRequests() async throws -> [PendingMembership] {
        let result: PendingMembershipsResponse = try await api.get("admin/memberships",
                                                                   query: [URLQueryItem(name: "status", value: "pending")])
        return result.memberships
    }

    func approveMembership(_ request: PendingMembership) async throws {
        let _: ApprovalResponse = try await api.send("POST", "admin/memberships/approve",
                                                     body: ApprovalBody(establishmentId: request.establishmentId,
                                                                        userId: request.userId))
    }

    func adminUsers() async throws -> [AdminUser] {
        try requireAdmin()
        let response: AdminUsersResponse = try await api.get("admin/users")
        return response.users
    }

    func setAdminRole(for user: AdminUser, enabled: Bool) async throws {
        try requireAdmin()
        let _: AdminRoleResponse = try await api.send("PATCH", "admin/users/\(user.id.uuidString)/role",
                                                      body: AdminRoleBody(role: enabled ? "admin" : "student"))
    }

    private func requireAdmin() throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
    }

    // MARK: - feed BQ-03

    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        save(newFilters, key: Keys.filters)
        Task { await refresh() }
    }

    func refresh() async {
        guard let userId = profile?.id else { return }
        let requested = filters
        do {
            let feed: FeedResponse = try await api.get("feed", query: requested.queryItems)
            // si cambiaron los filtros mientras llegaba la respuesta se bota la vieja
            guard requested == filters else { return }
            menus = feed.menus
            fetchedAt = feed.fetchedAt
            serverUnreachable = false
            save(CachedFeed(userId: userId, filters: requested, response: feed), key: Keys.feedCache)
            if isRestaurant, let mine: MenusResponse = try? await api.get("menus/mine") {
                ownMenus = mine.menus
            }
            await flushEvents()
        } catch {
            guard requested == filters else { return }
            serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadCachedFeed()
        }
    }

    private func loadCachedFeed() {
        guard let cached = Self.load(CachedFeed.self, key: Keys.feedCache),
              cached.userId == profile?.id, cached.filters == filters else {
            menus = []
            return
        }
        menus = cached.response.menus
        fetchedAt = cached.response.fetchedAt
    }

    // MARK: - menus guardados

    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }

    func toggleSaved(_ menu: DailyMenu) {
        guard let userId = profile?.id else { return }
        if isSaved(menu) {
            savedMenus.removeAll { $0.id == menu.id }
        } else {
            savedMenus.insert(SavedMenu(menu: menu, savedAt: .now), at: 0)
            track("menu_save", menu: menu)
        }
        save(savedMenus, key: Keys.savedMenus(userId))
    }

    // MARK: - detalle y reportes BQ-04

    /// trae la version actual del menu con el estado y los reportes que calcula el server
    /// si no se puede tira APIFailure tipo OFFLINE NOT_FOUND o GONE
    func menuDetail(_ menu: DailyMenu) async throws -> MenuDetail {
        try await api.get("menus/\(menu.id.uuidString)")
    }

    /// manda el reporte pegado a la version que vio el estudiante, nunca cambia el menu oficial
    /// devuelve lo que dijo el server, pending confirmed u observation
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) async throws -> String {
        let body = ReportBody(publicationId: menu.id, version: menu.version, kind: kind.rawValue,
                              note: note, observedWaitMinutes: waitMinutes)
        let response: ReportResponse = try await api.send("POST", "reports", body: body)
        if kind == .arrival { track("arrival", menu: menu) }
        await refresh()
        return response.status
    }

    // MARK: - publicar restaurantes

    /// crea un menu o una version nueva de old, al editar se manda la version que vio el dueño
    /// asi si alguien mas lo edito el server responde VERSION_CONFLICT y no se pisan los cambios
    func publish(_ body: MenuBody, replacing old: DailyMenu?) async throws {
        guard let establishmentId = body.establishmentId,
              approvedEstablishments.contains(where: { $0.id == establishmentId }) else {
            throw APIFailure(code: "VALIDATION_ERROR", message: "Selecciona un establecimiento aprobado.")
        }
        if let old {
            let _: MenuResponse = try await api.send("PUT", "menus/\(old.id.uuidString)", body: body)
        } else {
            let _: MenuResponse = try await api.send("POST", "menus", body: body)
        }
        await refresh()
    }

    func close(_ menu: DailyMenu) async throws {
        let _: CloseResponse = try await api.send("POST", "menus/\(menu.id.uuidString)/close", body: NoBody?.none)
        await refresh()
    }

    // MARK: - eventos y analitica

    /// mete el evento en la cola, el id se crea aca para que si se reenvia no cuente doble
    func track(_ kind: String, menu: DailyMenu) {
        if kind == "feed_impression" && !impressions.insert(menu.id).inserted { return }
        pendingEvents.append(RemoteEvent(eventId: UUID(), sessionId: sessionID, publicationId: menu.id,
                                         version: menu.version, kind: kind, occurredAt: .now))
        save(pendingEvents, key: Keys.pendingEvents)
        if !isOffline { Task { await flushEvents() } }
    }

    /// manda la cola de a 100, si falla se queda en cola para el proximo refresh
    private func flushEvents() async {
        guard profile != nil, !isOffline, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while !pendingEvents.isEmpty && !isOffline {
            let batch = Array(pendingEvents.prefix(100))
            do {
                let _: BatchResponse = try await api.send("POST", "events/batch", body: EventBatch(events: batch))
                pendingEvents.removeAll { batch.contains($0) }
                save(pendingEvents, key: Keys.pendingEvents)
            } catch {
                break
            }
        }
    }

    /// carga el panel de admin o las metricas del restaurante de los ultimos days dias
    /// primero manda la cola para que salga lo que acaba de hacer el usuario
    func loadPerformance(days: Int) async {
        guard !isOffline else { return }
        performanceError = nil
        do {
            try await loadAccount()
            await flushEvents()
            let query = [URLQueryItem(name: "days", value: String(days))]
            if isAdmin {
                adminDashboard[days] = try await api.get("admin/dashboard", query: query)
            } else if isRestaurant {
                restaurantPerformance[days] = try await api.get("restaurant/performance", query: query)
            }
        } catch {
            performanceError = error.localizedDescription
        }
    }

    // MARK: - guardar en el celular

    private func save<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? UniEatDates.encoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
}
