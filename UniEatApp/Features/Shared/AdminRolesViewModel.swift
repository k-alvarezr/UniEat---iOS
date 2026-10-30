import Combine
import Foundation

@MainActor
final class AdminRolesViewModel: FeatureViewModel {
    @Published var users: [AdminUser] = []
    @Published var selected: AdminUser?
    @Published var confirming = false
    @Published var workingID: UUID?
    @Published var message: String?
    private let service: AccountService
    private let session: SessionStore
    init(service: AccountService, session: SessionStore) {
        self.service = service; self.session = session; super.init(); observe(session)
    }
    var profileID: UUID? { session.profile?.id }
    func load() async {
        guard session.isAdmin else { users = []; return }
        do {
            users = try await service.adminUsers()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
    func change(_ user: AdminUser) async {
        workingID = user.id
        defer { workingID = nil; selected = nil }
        do {
            try await service.setAdminRole(for: user, enabled: user.role != "admin")
            await load()
            message = "Rol actualizado. El cambio se aplicará al actualizar la cuenta del usuario."
        } catch {
            message = error.localizedDescription
        }
    }
}
