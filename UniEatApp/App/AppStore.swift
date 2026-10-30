import Combine
import Foundation
import UniEatCore

/// pestañas de la app, para poder cambiar de pestaña desde cualquier pantalla
enum AppTab { case today, second, metrics, profile }

/// antes AppStore era el viewmodel de toda la app, ahora solo arma las piezas y maneja la pestaña
/// crea los servicios y los viewmodels de cada pantalla, les pasa lo que necesitan y los conecta entre si
/// cada pantalla tiene su propio viewmodel con su estado, aca no queda estado de pantallas
@MainActor
final class AppStore: ObservableObject {
    @Published var selectedTab: AppTab = .today   // pestaña visible

    // piezas compartidas, una sola instancia para toda la app
    let session: SessionStore                     // quien entro y sus permisos
    let connectivity: ConnectivityService         // si hay red o el server no responde
    let clock: ServerClock                        // hora del server
    /// la base swiftdata de reportes (#33), nil si no se pudo abrir, kevin agrega sus modelos aca (#34)
    let database: LocalDatabase?
    let storageError: String?                     // mensaje si la base no abrio, se muestra en perfil

    // viewmodels de cada pantalla, se inyectan en UniEatApp
    let feed: FeedViewModel
    let saved: SavedMenusViewModel
    let authentication: AuthViewModel
    let filters: FiltersViewModel
    let recommendation: RecommendationViewModel
    let publication: PublishViewModel
    let performance: PerformanceViewModel
    let profile: ProfileViewModel
    let establishments: EstablishmentViewModel
    let approvals: AdminApprovalsViewModel
    let roles: AdminRolesViewModel
    let reports: ReportingFacade                  // envio y cola de reportes
    private let events: EventService              // cola de eventos de analitica
    private let details: MenuDetailService        // pide y guarda detalles, se usa al crear cada detalle
    private var synchronization: Task<Void, Never>?   // tarea que manda colas y refresca, una a la vez

    /// arma toda la app en orden: auth -> api -> sesion -> servicios -> viewmodels -> conexiones entre ellos
    init() {
        // 1. autenticacion y api, la api pide el token al auth en cada llamada
        //    sessionIdentity sirve para botar respuestas que llegan despues de cerrar sesion
        let auth = SupabaseAuthService()
        let api = APIClient(configuration: .current, sessionIdentity: { auth.generation }) {
            try await auth.validAccessToken()
        }
        let session = SessionStore(auth: auth, api: api)
        let connectivity = ConnectivityService()
        let clock = ServerClock()
        let files = FileStore()

        // 2. base local, si no abre no se borra (puede tener reportes del usuario), se sigue sin ella y se avisa
        let database: LocalDatabase?
        do { database = try LocalDatabase(); storageError = nil }
        catch { database = nil; storageError = "No se pudieron cargar los datos guardados. Se conservaron para intentar recuperarlos; los reportes nuevos aún no se pueden guardar." }

        // 3. servicios y viewmodels, cada uno recibe solo lo que usa
        let events = EventService(api: api, session: session, connectivity: connectivity, clock: clock)
        let saved = SavedMenusViewModel(session: session, events: events, clock: clock)
        let feed = FeedViewModel(api: api, session: session, connectivity: connectivity, clock: clock, events: events)
        let reports = ReportingFacade(api: api, outbox: database, session: session, connectivity: connectivity, clock: clock)
        let accounts = AccountService(api: api, session: session)
        self.session = session; self.connectivity = connectivity; self.clock = clock; self.database = database
        self.events = events; self.saved = saved; self.feed = feed; self.reports = reports
        details = MenuDetailService(api: api, session: session, files: files, clock: clock)
        authentication = AuthViewModel(session: session)
        filters = FiltersViewModel(feed: feed)
        recommendation = RecommendationViewModel(feed: feed)
        publication = PublishViewModel(service: PublishingService(api: api, session: session, files: files),
                                       feed: feed, session: session, connectivity: connectivity, clock: clock)
        performance = PerformanceViewModel(api: api, session: session, events: events, connectivity: connectivity)
        profile = ProfileViewModel(session: session, saved: saved, reports: reports, storageError: storageError)
        establishments = EstablishmentViewModel(service: accounts, session: session)
        approvals = AdminApprovalsViewModel(service: accounts, session: session)
        roles = AdminRolesViewModel(service: accounts, session: session)

        // 4. conexiones: que pasa cuando vence la sesion, cambia la cuenta o vuelve la red
        api.onUnauthorized = { [weak session] in session?.signOut(message: "Tu sesión terminó. Inicia sesión de nuevo.") }
        session.onChange = { [weak self] in self?.accountChanged() }
        connectivity.onReconnect = { [weak self] in self?.synchronize() }
        // el server puede volver sin que cambie la red del celular, por eso tambien se mandan las colas
        // cuando el feed vuelve a cargar bien
        feed.onServiceAvailable = { [weak events, weak reports] in
            Task { await events?.flush(); await reports?.flushReports() }
        }

        // 5. si habia sesion en el keychain se entra directo
        Task { await session.restore() }
    }

    /// al entrar, salir o cambiar de cuenta se limpia lo de cada pantalla
    /// para que el siguiente usuario no vea nada del anterior, y se vuelven a cargar sus cosas
    private func accountChanged() {
        synchronization?.cancel(); selectedTab = .today
        connectivity.serverUnreachable = false
        events.accountChanged(); saved.accountChanged(); reports.accountChanged()
        publication.reset(); performance.reset(); recommendation.reset()
        authentication.password = ""; authentication.errorText = nil; authentication.isSubmitting = false
        roles.users = []; roles.selected = nil; roles.message = nil; roles.workingID = nil; roles.confirming = false
        approvals.requests = []; approvals.message = nil; approvals.workingId = nil
        establishments.reset()
        feed.accountChanged()
        synchronize(refreshFeed: false)   // el feed ya lo pide feed.accountChanged, aca solo las colas
    }

    /// manda la cola de eventos, luego la de reportes y luego refresca el feed, en ese orden
    /// si llega otra sincronizacion se cancela la anterior para no mandar dos veces lo mismo
    private func synchronize(refreshFeed: Bool = true) {
        synchronization?.cancel()
        synchronization = Task { [weak self] in
            guard let self, session.profile != nil else { return }
            await events.flush()
            guard !Task.isCancelled else { return }
            await reports.flushReports()
            guard !Task.isCancelled else { return }
            if refreshFeed { await feed.refresh() }
        }
    }

    /// cada detalle tiene su propio viewmodel, se crea aca porque necesita varias piezas compartidas
    func makeDetail(_ menu: DailyMenu) -> MenuDetailViewModel {
        MenuDetailViewModel(menu: menu, service: details, session: session, events: events,
                             saved: saved, connectivity: connectivity, clock: clock)
    }
    /// viewmodel de la hoja de reportar, uno por cada vez que se abre
    func makeReport(_ menu: DailyMenu, kind: ReportKind) -> ReportViewModel {
        ReportViewModel(menu: menu, kind: kind, reports: reports)
    }
}
