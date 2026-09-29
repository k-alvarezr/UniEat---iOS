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
    @Published private(set) var remotePerformance: [Int: PerformanceSummary] = [:]

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
        guard !forceOffline else { loadCachedFeed(); return }
        do {
            let feed: FeedResponse = try await api.get("feed", query: filters.queryItems)
            menus = feed.menus
            cachedAt = feed.fetchedAt
            serverUnreachable = false
            if let data = try? UniEatDates.encoder().encode(feed) {
                UserDefaults.standard.set(data, forKey: Keys.feedCache)
            }
            if isRestaurant, let mine: MenusResponse = try? await api.get("menus/mine") {
                remoteOwnMenus = mine.menus
            }
            await flushEvents()
        } catch {
            serverUnreachable = (error as? APIFailure)?.code == "OFFLINE"
            loadCachedFeed()
        }
    }

    private func loadCachedFeed() {
        guard let data = UserDefaults.standard.data(forKey: Keys.feedCache),
              let cached = try? UniEatDates.decoder().decode(FeedResponse.self, from: data) else { return }
        menus = cached.menus
        cachedAt = cached.fetchedAt
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
        authMessage = nil
        Task { await refresh() }
    }

    func signIn(email: String, password: String) async throws {
        let signedIn = try await auth.signIn(email: email, password: password)
        await startRemoteSession(fallback: signedIn)
        authMessage = nil
    }

    func signUp(email: String, password: String, name: String, role: String) async throws {
        if let signedIn = try await auth.signUp(email: email, password: password, name: name, role: role) {
            await startRemoteSession(fallback: signedIn)
            authMessage = nil
        } else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
        }
    }

    /// El rol que muestra la app es el verificado por el servidor (`GET /me`), nunca
    /// `user_metadata`. Sin conexión se reutiliza el último perfil verificado.
    private func startRemoteSession(fallback: Profile) async {
        isRemote = true
        menus = []
        loadCachedFeed()
        if let me: Profile = try? await api.get("me") {
            profile = me
            if let data = try? JSONEncoder().encode(me) { UserDefaults.standard.set(data, forKey: Keys.profile) }
        } else if let data = UserDefaults.standard.data(forKey: Keys.profile),
                  let cached = try? JSONDecoder().decode(Profile.self, from: data), cached.id == fallback.id {
            profile = cached
        } else {
            profile = Profile(id: fallback.id, displayName: fallback.displayName, role: "student")
        }
        await refresh()
    }

    func signOut() {
        auth.signOut()
        profile = nil
        isRemote = false
        remoteOwnMenus = []
        remotePerformance = [:]
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
        if pendingEvents.count >= 10 { Task { await flushEvents() } }
    }

    func flushEvents() async {
        guard isRemote, !isOffline, !isFlushing, !pendingEvents.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batch = Array(pendingEvents.prefix(100))
        do {
            let _: BatchResponse = try await api.send("POST", "events/batch", body: EventBatch(events: batch))
            pendingEvents.removeAll { batch.contains($0) }
            persistPendingEvents()
        } catch {
            // Se quedan en la cola local y se reenvían en la próxima actualización.
        }
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

    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) async throws {
        if isRemote {
            // Queda ligado a la versión exacta que vio el estudiante; nunca edita el menú oficial.
            let _: ReportResponse = try await api.send("POST", "reports", body: ReportBody(
                publicationId: menu.id, version: menu.version, kind: kind.rawValue,
                note: note, observedWaitMinutes: waitMinutes))
            if kind == .arrival { track("arrival", menu: menu) }
            await refresh()
            return
        }
        reports.append(SubmittedReport(menu: menu, kind: kind, note: note, waitMinutes: waitMinutes))
        if let data = try? UniEatDates.encoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: "unieat.demo.reports.v1")
        }
        if kind == .arrival { track("arrival", menu: menu) }
    }

    func publish(title: String, restaurantName: String, area: String, address: String,
                 entranceDescription: String,
                 validUntil: Date, dishes: [MenuDish], paymentMethods: [String],
                 replacing old: DailyMenu? = nil) async throws {
        if isRemote {
            let body = MenuBody(
                title: title, validUntil: validUntil, paymentMethods: paymentMethods,
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
            return remotePerformance[days]
                ?? PerformanceSummary(periodDays: days, impressions: 0, detailOpens: 0, selections: 0, reportedArrivals: 0)
        }
        let ownIDs = Set(ownMenus.map(\.id))
        let recent = events.filter { ownIDs.contains($0.menuID) && $0.date >= .now.addingTimeInterval(Double(-days * 86_400)) }
        return PerformanceSummary(periodDays: days,
                                  impressions: recent.filter { $0.kind == "feed_impression" }.count,
                                  detailOpens: recent.filter { $0.kind == "detail_open" }.count,
                                  selections: recent.filter { $0.kind == "selection" }.count,
                                  reportedArrivals: recent.filter { $0.kind == "arrival" }.count)
    }

    /// Agregados del servidor para los locales del dueño (nunca eventos individuales de estudiantes).
    func loadPerformance(days: Int) async {
        guard isRemote else { return }
        await flushEvents()
        if let summary: PerformanceSummary = try? await api.get("performance", query: [URLQueryItem(name: "days", value: String(days))]) {
            remotePerformance[days] = summary
        }
    }
}
