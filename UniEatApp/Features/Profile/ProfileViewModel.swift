import Combine
import Foundation
import UniEatCore

/// estado de perfil, lee la sesion, los guardados y la cola de reportes
@MainActor
final class ProfileViewModel: FeatureViewModel {
    @Published private(set) var isSigningOut = false
    private let session: SessionStore
    private let saved: SavedMenusViewModel
    let reports: ReportFacade
    // aviso si la base local no abrio
    let storageError: String?
    private let pilot: WaitIndicatorPilot?   // piloto de la BQ-08, perfil tiene el interruptor para participar
    init(session: SessionStore, saved: SavedMenusViewModel, reports: ReportFacade, storageError: String? = nil, pilot: WaitIndicatorPilot? = nil) {
        self.session = session
        self.saved = saved
        self.reports = reports
        self.storageError = storageError
        self.pilot = pilot
        super.init()
        observe(session)
        observe(saved)
        observe(reports)
        if let pilot { observe(pilot) }
    }
    var profile: Profile? { session.profile }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var savedMenus: [SavedMenuEntry] { saved.savedMenus }
    var accountError: String? { session.accountError }
    var isAccountVerified: Bool { session.isAccountVerified }
    var cachedAccountDate: Date? { session.cachedAccountDate }
    /// reportes que se borrarian al cerrar sesion, perfil avisa antes
    var unsentReports: Int { reports.pendingReportCount + reports.needsReviewCount }
    /// cierra sesion a mano: primero intenta mandar los reportes pendientes (si no hay red no hace nada)
    /// y despues borra del celular todo lo de la cuenta
    func signOut() async {
        guard !isSigningOut, let userID = session.profile?.id else { return }
        let generation = session.generation
        isSigningOut = true
        defer { isSigningOut = false }
        await reports.sendPendingReports()
        guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
        await session.signOutAndForget()
    }
    func refreshAccount() async { try? await session.refreshAccount() }
    /// reintenta tambien los reportes que el server rechazo
    func retryReports() async { await reports.sendPendingReports(retryRejected: true) }
    var canJoinPilot: Bool { pilot?.isStudent == true }
    var pilotEnabled: Bool { pilot?.isEnabled == true }
    var pilotMessage: String? { pilot?.message }
    func setPilotEnabled(_ value: Bool) { pilot?.setEnabled(value) }
}
