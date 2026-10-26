import Foundation
import Network
import SwiftUI
import UniEatCore

/// menu que el usuario guardo en el celular, se guarda por cuenta
struct SavedMenu: Codable, Identifiable {
    let menu: DailyMenu   // copia del menu como estaba al guardarlo
    let savedAt: Date     // cuando se guardo
    var id: UUID { menu.id }
}

/// ultimo feed que se bajo, sin internet solo se usa si es del mismo usuario y con los mismos filtros
private struct CachedFeed: Codable {
    let userId: UUID
    let filters: FeedFilters
    let response: FeedResponse
}

/// pestañas de la app, para poder cambiar de pestaña desde cualquier pantalla
enum AppTab { case today, second, metrics, profile }

/// este es el viewmodel de toda la app, las pantallas leen de aca y le piden cosas
/// el server decide vigencia orden y permisos, aca solo se muestra lo que responde
/// todo lo @Published avisa a las pantallas cuando cambia, y private(set) hace que solo el store lo cambie
@MainActor
final class AppStore: ObservableObject {
    // MARK: - sesion
    @Published private(set) var profile: Profile?                          // quien entro, nil es que no hay sesion y se ve el login
    @Published private(set) var memberships: [RemoteMembership] = []       // locales del usuario y si estan aprobados
    @Published private(set) var establishments: [RemoteEstablishment] = [] // datos de esos locales
    @Published var authMessage: String?                                    // aviso en el login, por ejemplo confirmar el correo

    // MARK: - feed
    @Published private(set) var menus: [DailyMenu] = []        // lo que mando el server, o la copia sin internet
    @Published private(set) var filters = FeedFilters()        // filtros aplicados
    @Published private(set) var fetchedAt = Date.now           // cuando se bajo el feed que se esta mostrando
    @Published private(set) var ownMenus: [DailyMenu] = []     // menus del restaurante, para publicar
    @Published private(set) var savedMenus: [SavedMenu] = []   // menus guardados de esta cuenta

    // MARK: - conexion
    @Published private(set) var isConnected = true          // el celular tiene internet
    @Published private(set) var serverUnreachable = false   // hay internet pero el server no responde

    // MARK: - navegacion
    @Published var selectedTab: AppTab = .today   // pestaña visible, la cambia por ejemplo el boton de perfil

    // MARK: - metricas
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]     // panel de admin por periodo, 7 o 28
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]  // metricas del restaurante por periodo
    @Published private(set) var performanceError: String?                               // error al cargar las metricas

    // servicios y estado interno, las pantallas no los ven
    private let auth = SupabaseAuthService()
    // la api pide el token al auth en cada llamada, es lazy porque necesita que self ya exista
    private lazy var api = APIClient(configuration: .current) { [unowned self] in
        try await self.auth.validAccessToken()
    }
    private let monitor = NWPathMonitor()             // avisa cuando cambia la conexion
    private let sessionID = UUID()                    // id de esta apertura de la app, va en cada evento
    private var countedThisSession: Set<String> = []  // acciones que ya se contaron en esta sesion, para no sumar dos veces
    private let onePerSession: Set<String> = ["feed_impression", "selection", "arrival"]  // acciones que valen una vez por menu y version
    private let maxQueuedEvents = 500                 // tope de la cola si el celular pasa mucho sin internet
    private var pendingEvents: [RemoteEvent] = []     // cola de eventos sin mandar
    private var isFlushing = false                    // para no mandar la cola dos veces a la vez

    // llaves con las que se guarda cada cosa en el celular
    private enum Keys {
        static let filters = "unieat.filters"
        static let feedCache = "unieat.remote.feed-cache.v1"
        static let pendingEvents = "unieat.remote.pending-events.v1"
        static func savedMenus(_ userId: UUID) -> String { "unieat.saved-menus.\(userId.uuidString)" }
    }

    /// se corre una vez al abrir la app
    init() {
        // 1. recuperar lo guardado: filtros y eventos que quedaron sin mandar
        filters = Self.load(FeedFilters.self, key: Keys.filters) ?? FeedFilters()
        pendingEvents = Self.load([RemoteEvent].self, key: Keys.pendingEvents) ?? []

        // 2. escuchar la red, cada cambio actualiza isConnected en el hilo de la pantalla
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "unieat.connectivity"))

        // 3. si habia sesion en el keychain se entra directo, si no se queda en el login
        Task {
            if let restored = await auth.restore() { await startSession(with: restored) }
        }
    }

    // MARK: - estado calculado

    /// sin internet o con el server caido
    var isOffline: Bool { !isConnected || serverUnreachable }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    /// lo de admin solo sirve con internet para no tocar datos viejos
    var isAdmin: Bool { profile?.role == "admin" && !isOffline }
    /// solo los locales que un admin ya aprobo, con esos se puede publicar
    var approvedEstablishments: [RemoteEstablishment] { establishments.filter(\.approved) }

    /// menus en el orden que manda el server, quitando los vencidos aunque vengan de la copia guardada
    var visibleMenus: [DailyMenu] { menus.filter { $0.isActive(at: .now) } }

    // MARK: - sesion

    /// login con correo y contraseña, si sale bien arranca la sesion
    func signIn(email: String, password: String) async throws {
        let signedIn = try await auth.signIn(email: email, password: password)
        await startSession(with: signedIn)
    }

    /// crea la cuenta, si supabase pide confirmar el correo no hay sesion todavia y se avisa
    func signUp(email: String, password: String, name: String) async throws {
        guard let signedIn = try await auth.signUp(email: email, password: password, name: name) else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
            return
        }
        await startSession(with: signedIn)
    }

    /// deja todo listo despues del login: guardados, copia del feed, rol real y feed nuevo
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

    /// pide al server quien es el usuario, su rol y sus locales
    private func loadAccount() async throws {
        let me: MeResponse = try await api.get("me")
        profile = me.profile
        memberships = me.establishments
        let mine: EstablishmentsResponse = try await api.get("establishments/mine")
        establishments = mine.establishments
    }

    /// vuelve a pedir la cuenta y el feed, por ejemplo despues de que aprueban un local
    func refreshAccount() async throws {
        try await loadAccount()
        await refresh()
    }

    /// borra la sesion, la copia del feed y la cola, y deja todo vacio para el siguiente usuario
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
        countedThisSession = []
        adminDashboard = [:]
        restaurantPerformance = [:]
        performanceError = nil
        selectedTab = .today   // al volver a entrar se arranca en hoy
    }

    // MARK: - locales y roles

    /// pide un local nuevo, queda pendiente hasta que un admin lo apruebe
    func requestEstablishment(_ request: EstablishmentRequestBody) async throws {
        let _: EstablishmentRequestResponse = try await api.send("POST", "establishments", body: request)
        // la solicitud ya se creo, si falla recargar no queremos que parezca que fallo el envio
        try? await loadAccount()
    }

    /// admin: solicitudes de locales que faltan por aprobar
    func pendingMembershipRequests() async throws -> [PendingMembership] {
        let result: PendingMembershipsResponse = try await api.get("admin/memberships",
                                                                   query: [URLQueryItem(name: "status", value: "pending")])
        return result.memberships
    }

    /// admin: aprueba un local, ese usuario pasa a ser restaurante
    func approveMembership(_ request: PendingMembership) async throws {
        let _: ApprovalResponse = try await api.send("POST", "admin/memberships/approve",
                                                     body: ApprovalBody(establishmentId: request.establishmentId,
                                                                        userId: request.userId))
    }

    /// admin: lista de usuarios con su rol
    func adminUsers() async throws -> [AdminUser] {
        try requireAdmin()
        let response: AdminUsersResponse = try await api.get("admin/users")
        return response.users
    }

    /// admin: da o quita el rol de admin a otro usuario
    func setAdminRole(for user: AdminUser, enabled: Bool) async throws {
        try requireAdmin()
        let _: AdminRoleResponse = try await api.send("PATCH", "admin/users/\(user.id.uuidString)/role",
                                                      body: AdminRoleBody(role: enabled ? "admin" : "student"))
    }

    // corta antes de llamar si no es admin, igual el server lo vuelve a revisar
    private func requireAdmin() throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
    }

    // MARK: - feed BQ-03

    /// guarda los filtros nuevos y pide el feed con ellos
    func updateFilters(_ newFilters: FeedFilters) {
        filters = newFilters
        save(newFilters, key: Keys.filters)
        Task { await refresh() }
    }

    /// pide el feed al server, guarda la copia para sin internet y manda la cola de eventos
    /// si falla se usa la copia guardada
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

    /// usa la copia guardada solo si es del mismo usuario y con los mismos filtros, si no deja la lista vacia
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

    /// true si el menu ya esta en guardados
    func isSaved(_ menu: DailyMenu) -> Bool { savedMenus.contains { $0.id == menu.id } }

    /// guarda o quita el menu de guardados, al guardar se cuenta el evento menu_save
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
    /// si automatic es true el server no la cuenta en las metricas, son recargas que no hizo el usuario
    func menuDetail(_ menu: DailyMenu, automatic: Bool = false) async throws -> MenuDetail {
        let query = automatic ? [URLQueryItem(name: "refresh", value: "auto")] : []
        return try await api.get("menus/\(menu.id.uuidString)", query: query)
    }

    /// manda el reporte pegado a la version que vio el estudiante, nunca cambia el menu oficial
    /// devuelve lo que dijo el server, pending confirmed u observation
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) async throws -> String {
        let body = ReportBody(publicationId: menu.id, version: menu.version, kind: kind.rawValue,
                              note: note, observedWaitMinutes: waitMinutes)
        let response: ReportResponse = try await api.send("POST", "reports", body: body)
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

    /// cierra el menu antes de que venza, desaparece del feed pero el historial se queda
    func close(_ menu: DailyMenu) async throws {
        let _: CloseResponse = try await api.send("POST", "menus/\(menu.id.uuidString)/close", body: NoBody?.none)
        await refresh()
    }

    // MARK: - eventos y analitica

    /// mete el evento en la cola, el id se crea aca para que si se reenvia no cuente doble
    /// ver una tarjeta o elegir un menu cuenta una sola vez por menu y version en cada sesion
    func track(_ kind: String, menu: DailyMenu) {
        // tocar muchas veces el mismo boton no suma
        if onePerSession.contains(kind) && !countedThisSession.insert(sessionKey(kind, menu)).inserted { return }
        pendingEvents.append(RemoteEvent(eventId: UUID(), sessionId: sessionID, publicationId: menu.id,
                                         version: menu.version, kind: kind, occurredAt: .now))
        // si la cola se pasa del tope se botan los mas viejos
        if pendingEvents.count > maxQueuedEvents {
            pendingEvents.removeFirst(pendingEvents.count - maxQueuedEvents)
        }
        save(pendingEvents, key: Keys.pendingEvents)
        if !isOffline { Task { await flushEvents() } }
    }

    /// true si en esta sesion el estudiante ya eligio esta version del menu
    func wasChosen(_ menu: DailyMenu) -> Bool {
        countedThisSession.contains(sessionKey("selection", menu))
    }

    /// true si en esta sesion el estudiante ya marco que llego a este menu
    func hasArrived(_ menu: DailyMenu) -> Bool {
        countedThisSession.contains(sessionKey("arrival", menu))
    }

    // llave de una accion sobre un menu, con la version para que un menu editado cuente aparte
    private func sessionKey(_ kind: String, _ menu: DailyMenu) -> String {
        "\(kind):\(menu.id):\(menu.version)"
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

    /// guarda cualquier cosa Codable en el celular con su llave (filtros, cache, colas, guardados)
    private func save<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? UniEatDates.encoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// lee lo guardado con esa llave y lo convierte al tipo pedido, nil si no hay o no se puede leer
    /// es static porque se usa en el init, antes de que el store este listo
    private static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
}
