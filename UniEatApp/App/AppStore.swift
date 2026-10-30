import Combine
import Foundation
import UniEatCore

enum AppTab { case today, second, metrics, profile }

/// Composition root and navigation only. Each feature owns its presentation state.
@MainActor
final class AppStore: ObservableObject {
    @Published var selectedTab: AppTab = .today
    let session: SessionStore
    let connectivity: ConnectivityService
    let clock: ServerClock
    /// One container for Juan's report models, saved dishes and feed snapshots.
    let database: LocalDatabase?
    let storageError: String?
    let images: FeedImageStore
    let pilot: WaitIndicatorPilot
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
    let reports: ReportingFacade
    private let events: EventService
    private let details: MenuDetailService
    private var synchronization: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?

    init() {
        let auth = SupabaseAuthService()
        let api = APIClient(configuration: .current, sessionIdentity: { auth.generation }) {
            try await auth.validAccessToken()
        }
        let session = SessionStore(auth: auth, api: api)
        let connectivity = ConnectivityService()
        let clock = ServerClock()
        let files = FileStore()
        let database: LocalDatabase?
        do { database = try LocalDatabase(); storageError = nil }
        catch { database = nil; storageError = "No se pudieron cargar los datos guardados. Se conservaron para intentar recuperarlos; los reportes nuevos aún no se pueden guardar." }
        let content = database.map { LocalContentService(container: $0.container) }
        let images = FeedImageStore()
        self.images = images
        ImageLibraryConfiguration.configure()
        Task { await images.clean() }
        let events = EventService(api: api, session: session, connectivity: connectivity, clock: clock)
        let pilot = WaitIndicatorPilot(api: api, session: session, clock: clock)
        self.pilot = pilot
        let saved = SavedMenusViewModel(session: session, events: events, clock: clock, content: content)
        let feed = FeedViewModel(api: api, session: session, connectivity: connectivity, clock: clock, events: events, content: content)
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
        profile = ProfileViewModel(session: session, saved: saved, reports: reports, storageError: storageError, pilot: pilot)
        establishments = EstablishmentViewModel(service: accounts, session: session)
        approvals = AdminApprovalsViewModel(service: accounts, session: session)
        roles = AdminRolesViewModel(service: accounts, session: session)
        api.onUnauthorized = { [weak session] in session?.signOut(message: "Tu sesión terminó. Inicia sesión de nuevo.") }
        session.onChange = { [weak self] in self?.accountChanged() }
        connectivity.onReconnect = { [weak self] in self?.synchronize() }
        feed.onMenusLoaded = { [weak self] menus in self?.prefetchImages(menus) }
        feed.prepareContext = { [weak pilot, weak events] in
            guard let events else { return }
            await pilot?.prepare(sessionID: events.sessionID)
        }
        events.metadataProvider = { [weak pilot, weak events, weak feed, weak connectivity] menu in
            guard let events else { return nil }
            return pilot?.metadata(menu: menu, sessionID: events.sessionID,
                live: feed?.isShowingCachedFeed == false && connectivity?.isOffline == false)
        }
        pilot.onParticipationChanged = { [weak events, weak feed] in
            events?.restartSession()
            Task { await feed?.refresh(force: true) }
        }
        // A service outage can recover without NWPathMonitor changing its network path.
        feed.onServiceAvailable = { [weak events, weak reports] in
            Task { await events?.flush(); await reports?.flushReports() }
        }
        Task { await session.restore() }
    }

    private func accountChanged() {
        imageTask?.cancel()
        synchronization?.cancel(); selectedTab = .today
        connectivity.serverUnreachable = false
        events.accountChanged(); pilot.accountChanged(); saved.accountChanged(); reports.accountChanged()
        publication.reset(); performance.reset(); recommendation.reset()
        authentication.password = ""; authentication.errorText = nil; authentication.isSubmitting = false
        roles.users = []; roles.selected = nil; roles.message = nil; roles.workingID = nil; roles.confirming = false
        approvals.requests = []; approvals.message = nil; approvals.workingId = nil
        establishments.reset()
        feed.accountChanged()
        synchronize(refreshFeed: false)
    }

    private func prefetchImages(_ menus: [DailyMenu]) {
        guard !connectivity.isOffline else { return }
        imageTask?.cancel()
        imageTask = Task(priority: .utility) { [images] in _ = await images.prefetch(menus) }
    }

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

    func makeDetail(_ menu: DailyMenu) -> MenuDetailViewModel {
        MenuDetailViewModel(menu: menu, service: details, session: session, events: events,
                             saved: saved, connectivity: connectivity, clock: clock, pilot: pilot)
    }
    func makeReport(_ menu: DailyMenu, kind: ReportKind, waitObservation: Bool = false) -> ReportViewModel {
        ReportViewModel(menu: menu, kind: kind, reports: reports, waitObservation: waitObservation)
    }
}
