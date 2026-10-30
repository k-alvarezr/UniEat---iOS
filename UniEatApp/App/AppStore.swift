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
    /// la base swiftdata: reportes (#33), menus guardados y copias del feed (#34), nil si no se pudo abrir
    let database: LocalDatabase?
    let storageError: String?                     // mensaje si la base no abrio, se muestra en perfil
    let images: FeedImageStore                    // fotos del feed guardadas en disco (#38)
    let pilot: WaitIndicatorPilot                 // piloto de la BQ-08, indicador de fila

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
    private let files: FileStore                  // archivos de detalle y borrador, se borran al cerrar sesion
    private let content: LocalContentService?
    private var synchronization: Task<Void, Never>?   // tarea que manda colas y refresca, una a la vez
    private var imageTask: Task<Void, Never>?         // descarga de fotos del feed en segundo plano
    private var imageRequestID = UUID()
    private var imageURLs: Set<String> = []

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
        self.files = files

        // 2. base local, si no abre no se borra (puede tener reportes del usuario), se sigue sin ella y se avisa
        let database: LocalDatabase?
        do {
            database = try LocalDatabase()
            storageError = nil
        } catch {
            database = nil
            storageError = "No se pudieron cargar los datos guardados. Se conservaron para intentar recuperarlos; los reportes nuevos aún no se pueden guardar."
        }
        // guardados y copias del feed se leen y escriben con un actor en segundo plano sobre la misma base
        let content = database.map { LocalContentService(container: $0.container) }
        self.content = content
        // fotos del feed en disco, al abrir se borran las viejas
        let images = FeedImageStore()
        self.images = images
        ImageLibraryConfiguration.configure()
        Task { await images.clean() }

        // 3. servicios y viewmodels, cada uno recibe solo lo que usa
        let events = EventService(api: api, session: session, connectivity: connectivity, clock: clock)
        let pilot = WaitIndicatorPilot(api: api, session: session, clock: clock)
        self.pilot = pilot
        let saved = SavedMenusViewModel(session: session, events: events, clock: clock, content: content)
        let feed = FeedViewModel(api: api, session: session, connectivity: connectivity, clock: clock, events: events, content: content)
        let reports = ReportingFacade(api: api, outbox: database, session: session, connectivity: connectivity, clock: clock)
        let accounts = AccountService(api: api, session: session)
        self.session = session
        self.connectivity = connectivity
        self.clock = clock
        self.database = database
        self.events = events
        self.saved = saved
        self.feed = feed
        self.reports = reports
        details = MenuDetailService(api: api, session: session, files: files, clock: clock)
        authentication = AuthViewModel(session: session)
        filters = FiltersViewModel(feed: feed)
        recommendation = RecommendationViewModel(feed: feed)
        publication = PublishViewModel(service: PublishingService(api: api, session: session, files: files),
                                       feed: feed, session: session, connectivity: connectivity, clock: clock)
        performance = PerformanceViewModel(api: api, session: session, events: events, connectivity: connectivity)
        profile = ProfileViewModel(session: session, saved: saved, reports: reports, storageError: storageError, pilot: pilot)
        establishments = EstablishmentViewModel(service: accounts, session: session)
        approvals = AdminApprovalsViewModel(service: accounts, session: session)
        roles = AdminRolesViewModel(service: accounts, session: session)

        // 4. conexiones: que pasa cuando vence la sesion, cambia la cuenta o vuelve la red
        api.onUnauthorized = { [weak session] in session?.signOut(message: "Tu sesión terminó. Inicia sesión de nuevo.") }
        session.onChange = { [weak self] in self?.accountChanged() }
        session.onForget = { [weak self] userID, generation in
            guard let self else { return }
            try await self.forget(userID, generation: generation)
        }
        connectivity.onReconnect = { [weak self] in self?.synchronize() }
        // cuando llega el feed se bajan sus fotos
        feed.onMenusLoaded = { [weak self] menus in self?.prefetchImages(menus) }
        // piloto de la BQ-08: antes de pedir el feed se asigna la variante de esta sesion
        // y cada evento lleva la variante para comparar los grupos en el tablero
        feed.prepareContext = { [weak pilot, weak events] in
            guard let events else { return }
            await pilot?.prepare(sessionID: events.sessionID)
        }
        events.metadataProvider = { [weak pilot, weak events, weak feed, weak connectivity] menu in
            guard let events else { return nil }
            return pilot?.metadata(menu: menu, sessionID: events.sessionID,
                live: feed?.isShowingCachedFeed == false && connectivity?.isOffline == false)
        }
        // si el usuario entra o sale del piloto se arranca una sesion de eventos nueva y se recarga el feed
        pilot.onParticipationChanged = { [weak events, weak feed] in
            events?.restartSession()
            Task { await feed?.refresh(force: true) }
        }
        // el server puede volver sin que cambie la red del celular, por eso tambien se mandan las colas
        // cuando el feed vuelve a cargar bien
        feed.onServiceAvailable = { [weak events, weak reports] in
            Task {
                await events?.flush()
                await reports?.flushReports()
            }
        }

        // 5. si habia sesion en el keychain se entra directo
        Task { await session.restore() }
    }

    /// al entrar, salir o cambiar de cuenta se limpia lo de cada pantalla
    /// para que el siguiente usuario no vea nada del anterior, y se vuelven a cargar sus cosas
    private func accountChanged() {
        imageTask?.cancel()
        imageTask = nil; imageRequestID = UUID(); imageURLs = []
        synchronization?.cancel()
        content?.setSession(userID: session.profile?.id, generation: session.generation)
        files.setSession(userID: session.profile?.id, generation: session.generation)
        selectedTab = .today
        connectivity.serverUnreachable = false
        // cada pieza limpia lo suyo, AppStore no toca el interior de las pantallas
        events.accountChanged()
        pilot.accountChanged()
        saved.accountChanged()
        reports.accountChanged()
        publication.reset()
        performance.reset()
        recommendation.reset()
        authentication.reset()
        roles.reset()
        approvals.reset()
        establishments.reset()
        feed.accountChanged()
        synchronize(refreshFeed: false)   // el feed ya lo pide feed.accountChanged, aca solo las colas
    }

    /// baja las fotos del feed en segundo plano para tenerlas sin red, cancela la descarga anterior
    private func prefetchImages(_ menus: [DailyMenu]) {
        guard !connectivity.isOffline else { return }
        let urls = Set(menus.compactMap(\.photoUrl))
        // Un refresco de los mismos menús no cancela y vuelve a iniciar su lote pendiente.
        guard imageTask == nil || urls != imageURLs else { return }
        imageTask?.cancel()
        let id = UUID()
        imageRequestID = id; imageURLs = urls
        imageTask = Task(priority: .utility) { [weak self, images] in
            _ = await images.prefetch(menus)
            guard let self, imageRequestID == id else { return }
            imageTask = nil; imageURLs = []
        }
    }

    /// al cerrar sesion a mano se borra lo que la cuenta dejo en el celular:
    /// reportes sin mandar, copias del feed, copias de detalles, borrador y eventos sin mandar
    /// los menus guardados se quedan, son marcadores que el usuario eligio y no estan en el server
    private func forget(_ userID: UUID, generation: UUID) async throws {
        files.invalidate(userID: userID)
        var failed = false
        do {
            guard let content else { throw APIFailure(code: "LOCAL_STORAGE_ERROR", message: "No se pudo abrir la base local.") }
            try await content.forget(userID: userID, generation: generation)
        } catch { failed = true }
        // Se intenta limpiar también los archivos si falló la base, y viceversa.
        do { try await files.removeAll(userId: userID, invalidating: generation) }
        catch { failed = true }
        LocalValues.remove(key: FeedViewModel.cacheKey)
        LocalValues.remove(key: EventService.pendingKey(userID))
        LocalValues.remove(key: EventService.rejectedKey(userID))
        LocalValues.remove(key: "unieat.report-failures.\(userID.uuidString)")   // motivos de la version anterior de la fachada
        if failed { throw APIFailure(code: "LOCAL_STORAGE_ERROR", message: "La limpieza local no se pudo completar.") }
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
    /// cachedAt es la hora de la copia de la que salio el menu, para mostrarla sin red
    func makeDetail(_ menu: DailyMenu, cachedAt: Date? = nil) -> MenuDetailViewModel {
        MenuDetailViewModel(menu: menu, service: details, session: session, events: events,
                             saved: saved, connectivity: connectivity, clock: clock, pilot: pilot,
                             initialFetchedAt: cachedAt ?? feed.fetchedAt)
    }
    /// viewmodel de la hoja de reportar, uno por cada vez que se abre
    /// waitObservation es cuando se reporta la fila desde el piloto de la BQ-08
    func makeReport(_ menu: DailyMenu, kind: ReportKind, waitObservation: Bool = false) -> ReportViewModel {
        ReportViewModel(menu: menu, kind: kind, reports: reports, waitObservation: waitObservation)
    }
}
