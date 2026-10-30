import Combine
import Foundation
import UniEatCore

@MainActor
/// estado de perfil, lee la sesion, los guardados y la cola de reportes
final class ProfileViewModel: FeatureViewModel {
    private let session: SessionStore
    private let saved: SavedMenusViewModel
    let reports: ReportingFacade
    // aviso si la base local no abrio
    let storageError: String?
    private let pilot: WaitIndicatorPilot?
    init(session: SessionStore, saved: SavedMenusViewModel, reports: ReportingFacade, storageError: String? = nil, pilot: WaitIndicatorPilot? = nil) {
        self.session = session; self.saved = saved; self.reports = reports
        self.storageError = storageError
        self.pilot = pilot
        super.init(); observe(session); observe(saved); observe(reports)
        if let pilot { observe(pilot) }
    }
    var profile: Profile? { session.profile }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var savedMenus: [SavedMenuEntry] { saved.savedMenus }
    var accountError: String? { session.accountError }
    func signOut() { session.signOut() }
    func refreshAccount() async { try? await session.refreshAccount() }
    /// reintenta tambien los reportes que el server rechazo
    func retryReports() async { await reports.flushReports(retryRejected: true) }
    var canJoinPilot: Bool { pilot?.isStudent == true }
    var pilotEnabled: Bool { pilot?.isEnabled == true }
    var pilotMessage: String? { pilot?.message }
    func setPilotEnabled(_ value: Bool) { pilot?.setEnabled(value) }
}
