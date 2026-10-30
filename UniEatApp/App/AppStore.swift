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

/// como le fue a un reporte guardado al mandarlo (se envio bien, falla por red, el server lo rechaza)
private enum SendResult { case sent, retry, rejected }

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
    @Published private(set) var pendingReportCount = 0      // reportes guardados esperando red

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
    private let database = LocalDatabase()            // reportes sin mandar, swiftdata
    private let files = FileStore()                   // detalles y borrador en archivos
    private var isFlushingReports = false             // para no mandar la cola de reportes dos veces a la vez
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

    /// pide al server quien es el usuario y sus locales, las dos no dependen una de la otra
    /// entonces van en paralelo, si una falla la otra se cancela sola al salir de la funcion
    private func loadAccount() async throws {
        async let me: MeResponse = try await api.get("me")
        async let mine: EstablishmentsResponse = try await api.get("establishments/mine")
        let (account, owned) = try await (me, mine)
        profile = account.profile
        memberships = account.establishments
        establishments = owned.establishments
    }

    /// vuelve a pedir la cuenta y el feed, por ejemplo despues de que aprueban un local
    func refreshAccount() async throws {
        try await loadAccount()
        await refresh()
    }

    /// borra la sesion, la copia del feed y la cola, y deja todo vacio para el siguiente usuario
    func signOut() {
        // lo guardado es de esta cuenta, el siguiente usuario no lo debe ver
        if let userId = profile?.id {
            database.deleteAll(userId: userId)
            files.removeAll(userId: userId)
        }
        pendingReportCount = 0
        
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
            await flushReports()
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
        let detail: MenuDetail = try await api.get("menus/\(menu.id.uuidString)", query: query)
            // se guarda la copia para poder abrir el detalle sin red
            if let userId = profile?.id {
                files.save(detail, name: "detail-\(menu.id.uuidString)", folder: .caches, userId: userId)
            }
            return detail
        }
    
    /// ultima copia guardada del detalle, nil si nunca se abrio con red
    /// leer el disco y decodificar va en un hilo de fondo con prioridad utility (es util pero el usuario no lo ve, puede esperar un poquito) (no traba la pantalla)
    /// .value espera el resultado de esa tarea, y como AppStore es @MainActor la linea despues del await ya corre en el hilo principal
    func cachedDetail(for menu: DailyMenu) async -> MenuDetail? {
        guard let userId = profile?.id else { return nil }
        let files = files // copia de la estructura para llevarla al otro hilo
        let name = "detail-\(menu.id.uuidString)"
        return await Task.detached(priority: .utility){
            files.load(MenuDetail.self, name: name, folder: .caches, userId: userId)
        }.value
    }


    /// manda el reporte pegado a la version que vio el estudiante, nunca cambia el menu oficial
    /// devuelve lo que dijo el server, pending confirmed u observation
    func submitReport(for menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) async throws -> String {
        guard let userId = profile?.id else { throw APIFailure.unexpected }
        // sin red no se pierde, queda en la base y se manda cuando vuelva
        if isOffline {
            queueReport(userId: userId, menu: menu, kind: kind, note: note, waitMinutes: waitMinutes)
            return "queued"
        }
        let body = ReportBody(publicationId: menu.id,
                              version: menu.version,
                              kind: kind.rawValue,
                              note: note,
                              observedWaitMinutes: waitMinutes)
        do {
            let response: ReportResponse = try await api.send("POST", "reports", body: body)
            await refresh()
            return response.status
            } catch let failure as APIFailure where failure.code == "OFFLINE" {
            // se fue la red justo al mandar
            queueReport(userId: userId, menu: menu, kind: kind, note: note, waitMinutes: waitMinutes)
            return "queued"
        }
    }
    
    private func queueReport(userId: UUID, menu: DailyMenu, kind: ReportKind, note: String, waitMinutes: Int?) {
        database.enqueueReport(userId: userId, menu: menu, kind: kind.rawValue, note: note, waitMinutes: waitMinutes)
        pendingReportCount = database.pendingReports(userId: userId).count
    }
    
    /// manda todos los reportes guardados a la vez, cada uno en una tarea hija del grupo
    private func flushReports() async {
        guard let userId = profile?.id, !isOffline, !isFlushingReports else {return} //lista de reportes a mandar
        isFlushingReports = true
        defer { isFlushingReports = false }
        
        // 1. sacar de swiftdata lo que se va a mandar, los modelos de la base no pueden cambiar de hilo
        //    entonces se copian el id y el body que si son Sendable
        var outbox: [(id: UUID, body: ReportBody)] = []
        for report in database.pendingReports(userId: userId) {
            if let body = report.body   { outbox.append((report.id, body)) }
            else { database.remove(report) }
        }
        guard !outbox.isEmpty else { return } //que la lista a mandar no este vacia, o aborta
        
        // 2. una tarea hija por reporte con prioridad utility, todas esperan la red al mismo tiempo
        //    el grupo no termina hasta que terminan todas sus hijas (prioridad utility, como el resto)
        let api = api
        let results = await withTaskGroup(of: (UUID, SendResult).self){
            group in
            for item in outbox {
                group.addTask(priority: .utility) {
                    do {
                        let _: ReportResponse = try await api.send("POST", "reports", body: item.body)
                        return (item.id, .sent)       // todo salio cool
                    } catch let failure as APIFailure where failure.code == "OFFLINE" {
                        return (item.id, .retry)      // sin red, se queda para la proxima
                    } catch {
                        return (item.id, .rejected)   // el server lo rechazo, reintentar no sirve
                    }
                }
            }
            var all: [(UUID, SendResult)] = []
            for await result in group { all.append(result) }
            return all
        }
        // 3. de vuelta en el hilo principal se actualiza la base, swiftdata solo se toca aca
        for (id, result) in results where result != .retry { database.remove(id: id) } //remueve todo lo que no sea para reintentar
                pendingReportCount = database.pendingReports(userId: userId).count     //actualiza cuantos reportes pendientes quedan
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
    
    /// borrador de publicar, va en application support porque es trabajo del restaurante
    func saveDraft(_ draft: PublishDraft) {
        guard let userId = profile?.id else { return }
        files.save(draft, name: "publish-draft", folder: .support, userId: userId)
    }

    /// lee el borrador en un hilo de fondo, igual que el detalle
    /// guardar si va directo para que nunca un borrador viejo pise uno nuevo (que el archivo termine con el borrador viejo encima del nuevo)
    /// (.utility: es util pero el usuario no lo ve, puede esperar un poquito) (no traba la pantalla)
    /// .value espera el resultado de esa tarea, y como AppStore es @MainActor la linea despues del await ya corre en el hilo principal
    func loadDraft() async -> PublishDraft? {
        guard let userId = profile?.id else { return nil }
        let files = files
        return await Task.detached(priority: .utility){
            files.load(PublishDraft.self, name: "publish-draft", folder: .support, userId: userId)
        }.value
    }

    func clearDraft() {
        guard let userId = profile?.id else { return }
        files.remove(name: "publish-draft", folder: .support, userId: userId)
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
