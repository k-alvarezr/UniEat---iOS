import Combine
import Foundation

@MainActor
/// estado de la pantalla de roles que antes estaba en AdminRolesView
final class AdminRolesViewModel: FeatureViewModel {
    @Published var users: [AdminUser] = []
    // usuario al que se le va a cambiar el rol
    @Published var selected: AdminUser?
    // muestra la confirmacion antes de cambiar el rol
    @Published var confirming = false
    @Published var workingID: UUID?
    @Published var message: String?
    private let service: AccountService
    private let session: SessionStore
    init(service: AccountService, session: SessionStore) {
        self.service = service; self.session = session; super.init(); observe(session)
    }
    /// id propio, para no dejar que el admin se quite el rol a si mismo desde la lista
    var profileID: UUID? { session.profile?.id }
    /// lista de usuarios, solo si es admin
    func load() async {
        guard session.isAdmin else { users = []; return }
        do {
            users = try await service.adminUsers()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
    /// da o quita admin y recarga la lista
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
