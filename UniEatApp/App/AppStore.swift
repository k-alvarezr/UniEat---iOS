import Foundation
import Network
import SwiftUI
import UniEatCore

struct InteractionEvent: Codable, Identifiable {
    let id: UUID
    let menuID: UUID
    let kind: String
    let date: Date

    init(menuID: UUID, kind: String) {
        id = UUID()
        self.menuID = menuID
        self.kind = kind
        date = .now
    }
}

struct SubmittedReport: Codable, Identifiable {
    let id: UUID
    let menuID: UUID
    let menuVersion: Int
    let kind: ReportKind
    let note: String
    let waitMinutes: Int?
    let date: Date

    init(menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) {
        id = UUID()
        menuID = menu.id
        menuVersion = menu.version
        self.kind = kind
        self.note = note
        self.waitMinutes = waitMinutes
        date = .now
    }
}

struct SavedMenu: Codable, Identifiable {
    let menu: DailyMenu
    let savedAt: Date
    var id: UUID { menu.id }
}

private struct CachedRemoteFeed: Codable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var menus: [DailyMenu] = SampleMenus.all
    @Published private(set) var filters: FeedFilters = FeedFilters()
    @Published private(set) var isConnected = true
    @Published var forceOffline = false
    @Published private(set) var cachedAt = Date.now
    @Published private(set) var reports: [SubmittedReport] = []
    @Published private(set) var events: [InteractionEvent] = []
    @Published var authMessage: String?
    /// true con una cuenta real: menús, reportes, eventos y métricas vienen de la API compartida.
    /// false en "Probar sin servidor", que conserva la demostración local igual que antes.
    @Published private(set) var isRemote = false
    @Published private(set) var serverUnreachable = false
    @Published private(set) var remoteOwnMenus: [DailyMenu] = []
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]
    @Published private(set) var performanceError: String?
    @Published private(set) var savedMenus: [SavedMenu] = []
    @Published private(set) var remoteMemberships: [RemoteMembership] = []
    @Published private(set) var remoteEstablishments: [RemoteEstablishment] = []

    let configuration = AppConfiguration.current
    private let repository: MenuRepository = DemoMenuRepository()
    private let ranking: FeedRankingStrategy = ContextualRankingStrategy()
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "unieat.connectivity")
    private let auth = SupabaseAuthService()
    private lazy var api = APIClient(configuration: configuration) { [unowned self] in
        try await self.auth.validAccessToken()
    }
    private var impressions: Set<UUID> = []
    private let sessionID = UUID()
    private var pendingEvents: [RemoteEvent] = []
    private var isFlushing = false
    private let demoStudentID = UUID(uuidString: "FEED0000-0000-4000-8000-000000000001")!
    private let demoRestaurantID = UUID(uuidString: "FEED0000-0000-4000-8000-000000000002")!

    private enum Keys {
        static let feedCache = "unieat.remote.feed-cache.v1"
        static let profile = "unieat.remote.profile.v1"
        static let pendingEvents = "unieat.remote.pending-events.v1"
        static func savedMenus(_ userId: UUID) -> String { "unieat.saved-menus.\(userId.uuidString)" }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "unieat.filters"),
           let saved = try? JSONDecoder().decode(FeedFilters.self, from: data) {
            filters = saved
        }
        if let data = UserDefaults.standard.data(forKey: "unieat.demo.reports.v1"),
           let saved = try? UniEatDates.decoder().decode([SubmittedReport].self, from: data) {
            reports = saved
        }
        if let data = UserDefaults.standard.data(forKey: "unieat.demo.events.v1"),
           let saved = try? UniEatDates.decoder().decode([InteractionEvent].self, from: data) {
            events = saved
        }
        if let data = UserDefaults.standard.data(forKey: Keys.pendingEvents),
           let saved = try? UniEatDates.decoder().decode([RemoteEvent].self, from: data) {
            pendingEvents = saved
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: monitorQueue)
        Task {
            if let restored = await auth.restore() {
                await startRemoteSession(fallback: restored)
            } else {
                await refresh()
            }
        }
    }

    var isOffline: Bool { forceOffline || !isConnected || (isRemote && serverUnreachable) }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    var isAdmin: Bool { isRemote && profile?.role == "admin" && !isOffline }
    var approvedEstablishments: [RemoteEstablishment] {
        remoteEstablishments.filter(\.approved)
    }
    var rankedMenus: [DailyMenu] {
        // En línea el servidor ya filtró y ordenó (rank-v1). El filtro por fecha protege la
        // copia guardada: un menú vencido no reaparece solo porque estaba en caché.
        isRemote ? menus.filter { $0.isActive(at: .now) } : ranking.ranked(menus, for: filters, at: .now)
    }
    var topRecommendation: DailyMenu? { rankedMenus.first }
    func explanation(for menu: DailyMenu) -> String {
        isRemote ? menu.explanation : ranking.explanation(for: menu, filters: filters, at: .now)
    }
    var ownMenus: [DailyMenu] {
        if isRemote { return remoteOwnMenus }
        guard let id = profile?.id else { return [] }
        return menus.filter { $0.establishmentId == id }
    }

    func refresh() async {
        guard isRemote else {
            do {
                menus = try await repository.loadMenus()
                cachedAt = .now
            } catch {
                authMessage = "No se pudo abrir la copia local de los menús."
            }
            return
        }
        guard !forceOffline else { loadCachedFeed(for: profile?.id); return }
        let requestedFilters = filters
        do {
            let feed: FeedResponse = try await api.get("feed", query: requestedFilters.queryItems)
            guard requestedFilters == filters else { return }
            menus = feed.menus
            cachedAt = feed.fetchedAt
            serverUnreachable = false
            if let userId = profile?.id,
               let data = try? UniEatDates.encoder().encode(CachedRemoteFeed(
                   userId: userId, filters: requestedFilters, response: feed)) {
                UserDefaults.standard.set(data, forKey: Keys.feedCache)
            }
            if isRestaurant, let mine: MenusResponse = try? await api.get("menus/mine") {
                remoteOwnMenus = mine.menus
            }
            await flushEvents()
        } catch {
            guard requestedFilters == filters else { return }
            serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadCachedFeed(for: profile?.id)
        }
    }

    private func loadCachedFeed(for userId: UUID?) {
        guard let data = UserDefaults.standard.data(forKey: Keys.feedCache),
              let cached = try? UniEatDates.decoder().decode(CachedRemoteFeed.self, from: data),
              cached.userId == userId, cached.filters == filters else {
            menus = []
            return
        }
        menus = cached.response.menus
        cachedAt = cached.response.fetchedAt
    }

    func updateFilters(_ value: FeedFilters) {
        filters = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "unieat.filters")
        }
        if isRemote {
            Task { await refresh() }
        } else {
            trackGlobal("filter_apply")
        }
    }

    func enterDemo(role: String) {
        isRemote = false
        profile = Profile(id: role == "restaurant" ? demoRestaurantID : demoStudentID,
                          displayName: role == "restaurant" ? "Mi restaurante" : "Estudiante Uniandes", role: role)
        loadSavedMenus()
        authMessage = nil
        Task { await refresh() }
    }

    func signIn(email: String, password: String) async throws {
        let signedIn = try await auth.signIn(email: email, password: password)
        await startRemoteSession(fallback: signedIn)
        authMessage = nil
    }

    func signUp(email: String, password: String, name: String) async throws {
        if let signedIn = try await auth.signUp(email: email, password: password, name: name) {
            await startRemoteSession(fallback: signedIn)
            authMessage = nil
        } else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
        }
    }

    /// El rol privilegiado se verifica con `GET /me`; sin conexión se vuelve a estudiante.
    private func startRemoteSession(fallback: Profile) async {
        isRemote = true
        profile = fallback
        loadSavedMenus()
        menus = []
        loadCachedFeed(for: fallback.id)
        do {
            try await loadRemoteAccount()
        } catch {
            profile = Profile(id: fallback.id, displayName: fallback.displayName, role: "student")
        }
        await refresh()
    }

    private func loadRemoteAccount() async throws {
        let me: MeResponse = try await api.get("me")
        profile = me.profile
        remoteMemberships = me.establishments
        if let data = try? JSONEncoder().encode(me.profile) {
            UserDefaults.standard.set(data, forKey: Keys.profile)
        }
        let mine: EstablishmentsResponse = try await api.get("establishments/mine")
        remoteEstablishments = mine.establishments
    }

    func refreshAccount() async throws {
        guard isRemote else { return }
        try await loadRemoteAccount()
        await refresh()
    }

    func requestEstablishment(name: String, area: String, address: String,
                              entranceDescription: String, paymentMethods: [String]) async throws {
        let body = EstablishmentRequestBody(name: name, area: area, address: address,
                                            entranceDescription: entranceDescription,
                                            paymentMethods: paymentMethods)
        let _: EstablishmentRequestResponse = try await api.send("POST", "establishments", body: body)
        // La solicitud ya existe si el POST respondió 201. Un fallo al recargar no debe
        // presentarse como fallo de envío ni provocar que el usuario la duplique.
        try? await loadRemoteAccount()
    }

    func pendingMembershipRequests() async throws -> [PendingMembership] {
        let result: PendingMembershipsResponse = try await api.get("admin/memberships", query: [
            URLQueryItem(name: "status", value: "pending")
        ])
        return result.memberships
    }

    func approveMembership(_ request: PendingMembership) async throws {
        let _: ApprovalResponse = try await api.send("POST", "admin/memberships/approve", body:
            ApprovalBody(establishmentId: request.establishmentId, userId: request.userId))
    }

    func adminUsers() async throws -> [AdminUser] {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
        let response: AdminUsersResponse = try await api.get("admin/users")
        return response.users
    }

    func setAdminRole(for user: AdminUser, enabled: Bool) async throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
        let _: AdminRoleResponse = try await api.send("PATCH", "admin/users/\(user.id.uuidString)/role",
                                                  body: AdminRoleBody(role: enabled ? "admin" : "student"))
    }

    func signOut() {
        auth.signOut()
        profile = nil
        isRemote = false
        remoteOwnMenus = []
        adminDashboard = [:]
        restaurantPerformance = [:]
        performanceError = nil
        savedMenus = []
        remoteMemberships = []
        remoteEstablishments = []
        pendingEvents = []
        persistPendingEvents()
        UserDefaults.standard.removeObject(forKey: Keys.profile)
        UserDefaults.standard.removeObject(forKey: Keys.feedCache)
        menus = SampleMenus.all
        impressions.removeAll()
    }

    func track(_ kind: String, menu: DailyMenu) {
        if kind == "feed_impression" && !impressions.insert(menu.id).inserted { return }
        guard isRemote else {
            events.append(InteractionEvent(menuID: menu.id, kind: kind))
            persistEvents()
            return
        }
        // eventId se genera aquí para que reenviar un lote nunca cuente dos veces en el servidor.
        pendingEvents.append(RemoteEvent(eventId: UUID(), sessionId: sessionID, publicationId: menu.id,
                                         version: menu.version, kind: kind, occurredAt: .now))
        persistPendingEvents()
        if !isOffline { Task { await flushEvents() } }
    }

    func flushEvents() async {
        guard isRemote, !isOffline, !isFlushing, !pendingEvents.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        while !pendingEvents.isEmpty && !isOffline {
            let batch = Array(pendingEvents.prefix(100))
            do {
                let _: BatchResponse = try await api.send("POST", "events/batch", body: EventBatch(events: batch))
                pendingEvents.removeAll { batch.contains($0) }
                persistPendingEvents()
            } catch {
                // Se quedan en la cola local y se reenvían en la próxima actualización.
                break
            }
        }
    }

    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }

    func toggleSaved(_ menu: DailyMenu) {
        guard let userId = profile?.id else { return }
        if isSaved(menu) {
            savedMenus.removeAll { $0.id == menu.id }
        } else {
            savedMenus.insert(SavedMenu(menu: menu, savedAt: .now), at: 0)
            track("menu_save", menu: menu)
        }
        if let data = try? UniEatDates.encoder().encode(savedMenus) {
            UserDefaults.standard.set(data, forKey: Keys.savedMenus(userId))
        }
    }

    private func loadSavedMenus() {
        guard let userId = profile?.id,
              let data = UserDefaults.standard.data(forKey: Keys.savedMenus(userId)),
              let saved = try? UniEatDates.decoder().decode([SavedMenu].self, from: data) else {
            savedMenus = []
            return
        }
        savedMenus = saved
    }

    private func trackGlobal(_ kind: String) {
        events.append(InteractionEvent(menuID: UUID(), kind: kind))
        persistEvents()
    }

    private func persistEvents() {
        if let data = try? UniEatDates.encoder().encode(events) {
            UserDefaults.standard.set(data, forKey: "unieat.demo.events.v1")
        }
    }

    private func persistPendingEvents() {
        if let data = try? UniEatDates.encoder().encode(pendingEvents) {
            UserDefaults.standard.set(data, forKey: Keys.pendingEvents)
        }
    }

    func pendingReports(for menu: DailyMenu) -> Int {
        if isRemote { return menu.pendingReports }
        return menu.pendingReports + reports.filter { $0.menuID == menu.id && $0.menuVersion == menu.version }.count
    }

    /// BQ-04: versión actual del menú con estado, vigencia y reportes calculados por el servidor.
    /// Devuelve nil en modo demo; lanza `APIFailure` (OFFLINE, NOT_FOUND, GONE…) si el servidor no lo entrega.
    func menuDetail(_ menu: DailyMenu) async throws -> MenuDetail? {
        guard isRemote else { return nil }
        guard !forceOffline else { throw APIFailure.offline }
        return try await api.get("menus/\(menu.id.uuidString)")
    }

    @discardableResult
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) async throws -> String {
        if isRemote {
            // Queda ligado a la versión exacta que vio el estudiante; nunca edita el menú oficial.
            let response: ReportResponse = try await api.send("POST", "reports", body: ReportBody(
                publicationId: menu.id, version: menu.version, kind: kind.rawValue,
                note: note, observedWaitMinutes: waitMinutes))
            if kind == .arrival { track("arrival", menu: menu) }
            await refresh()
            return response.status
        }
        reports.append(SubmittedReport(menu: menu, kind: kind, note: note, waitMinutes: waitMinutes))
        if let data = try? UniEatDates.encoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: "unieat.demo.reports.v1")
        }
        if kind == .arrival { track("arrival", menu: menu) }
        return [.unavailable, .price, .location].contains(kind) ? "pending" : "observation"
    }

    func publish(establishmentId: UUID?, title: String, restaurantName: String, area: String, address: String,
                 entranceDescription: String,
                 validUntil: Date, dishes: [MenuDish], paymentMethods: [String],
                 replacing old: DailyMenu? = nil) async throws {
        if isRemote {
            let selectedId = old?.establishmentId ?? establishmentId
            guard let selectedId, approvedEstablishments.contains(where: { $0.id == selectedId }) else {
                throw APIFailure(code: "VALIDATION_ERROR", message: "Selecciona un establecimiento aprobado.")
            }
            let body = MenuBody(
                establishmentId: selectedId, title: title, validUntil: validUntil, paymentMethods: paymentMethods,
                dishes: dishes.map { dish in
                    MenuBody.Dish(name: dish.name, description: dish.description, category: dish.category,
                                  priceCop: dish.priceCop, dietaryKnown: dish.dietaryKnown,
                                  dietaryTags: dish.dietaryKnown ? dish.dietaryTags : [])
                },
                establishmentName: restaurantName, area: area,
                address: address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address,
                entranceDescription: entranceDescription,
                // Al editar se envía la versión que vio el dueño; el servidor responde 409 si cambió.
                expectedVersion: old?.version)
            if let old {
                let _: MenuResponse = try await api.send("PUT", "menus/\(old.id.uuidString)", body: body)
            } else {
                let _: MenuResponse = try await api.send("POST", "menus", body: body)
            }
            await refresh()
            return
        }
        guard let owner = profile, owner.role == "restaurant" else { return }
        guard old == nil || old?.establishmentId == owner.id else { return }
        let menu: DailyMenu
        if let old {
            menu = old.revised(title: title, establishmentName: restaurantName, area: area,
                               address: address, entranceDescription: entranceDescription,
                               validUntil: validUntil, items: dishes,
                               paymentMethods: paymentMethods)
        } else {
            menu = DailyMenu(title: title, validUntil: validUntil, establishmentId: owner.id,
                        establishmentName: restaurantName, area: area, address: address,
                        entranceDescription: entranceDescription,
                        paymentMethods: paymentMethods, items: dishes,
                        lowestPriceCop: dishes.map(\.priceCop).min() ?? 0)
        }
        try await repository.saveMenu(menu)
        await refresh()
    }

    func close(_ menu: DailyMenu) async throws {
        if isRemote {
            let _: CloseResponse = try await api.send("POST", "menus/\(menu.id.uuidString)/close", body: NoBody?.none)
            await refresh()
            return
        }
        guard let owner = profile, owner.role == "restaurant",
              menu.establishmentId == owner.id else { return }
        try await repository.saveMenu(menu.closed())
        await refresh()
    }

    func performance(days: Int) -> PerformanceSummary {
        if isRemote {
            return (isAdmin ? adminDashboard[days]?.engagement : restaurantPerformance[days])
                ?? PerformanceSummary(periodDays: days, impressions: 0, detailOpens: 0, selections: 0, reportedArrivals: 0)
        }
        let ownIDs = Set(ownMenus.map(\.id))
        let recent = events.filter { ownIDs.contains($0.menuID) && $0.date >= .now.addingTimeInterval(Double(-days * 86_400)) }
        return PerformanceSummary(periodDays: days,
                                  impressions: recent.filter { $0.kind == "feed_impression" }.count,
                                  detailOpens: recent.filter { $0.kind == "detail_open" }.count,
                                  selections: recent.filter { $0.kind == "selection" }.count,
                                  reportedArrivals: recent.filter { $0.kind == "arrival" }.count,
                                  savedMenus: recent.filter { $0.kind == "menu_save" }.count,
                                  locationOpens: recent.filter { $0.kind == "location_open" }.count,
                                  reports: reports.filter { ownIDs.contains($0.menuID) && $0.date >= .now.addingTimeInterval(Double(-days * 86_400)) }.count)
    }

    /// Agregados iOS del servidor, visibles únicamente para administradores.
    func loadPerformance(days: Int) async {
        guard isRemote && !isOffline else { return }
        performanceError = nil
        do {
            try await loadRemoteAccount()
            await flushEvents()
            let query = [URLQueryItem(name: "days", value: String(days))]
            if isAdmin {
                let snapshot: AdminDashboardSnapshot = try await api.get("admin/dashboard", query: query)
                adminDashboard[days] = snapshot
            } else if isRestaurant {
                let summary: PerformanceSummary = try await api.get("restaurant/performance", query: query)
                restaurantPerformance[days] = summary
            }
        } catch {
            performanceError = error.localizedDescription
        }
    }
}
