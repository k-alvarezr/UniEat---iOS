import Combine
import Foundation
import UniEatCore

@MainActor
final class ProfileViewModel: FeatureViewModel {
    private let session: SessionStore
    private let saved: SavedMenusViewModel
    let reports: ReportingFacade
    let storageError: String?
    init(session: SessionStore, saved: SavedMenusViewModel, reports: ReportingFacade, storageError: String? = nil) {
        self.session = session; self.saved = saved; self.reports = reports
        self.storageError = storageError
        super.init(); observe(session); observe(saved); observe(reports)
    }
    var profile: Profile? { session.profile }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var savedMenus: [SavedMenu] { saved.savedMenus }
    var accountError: String? { session.accountError }
    func signOut() { session.signOut() }
    func refreshAccount() async { try? await session.refreshAccount() }
    func retryReports() async { await reports.flushReports(retryRejected: true) }
}
