import Combine
import Foundation

/// estado de la pantalla de roles que antes estaba en AdminRolesView
@MainActor
final class AdminRolesViewModel: FeatureViewModel {
    @Published var users: [AdminUser] = []
    // usuario al que se le va a cambiar el rol
    @Published var selected: AdminUser?
    // muestra la confirmacion antes de cambiar el rol
    @Published var confirming = false
    @Published var workingID: UUID?
    @Published var message: String?
    @Published private(set) var isLoading = false
    private let service: AccountService
    private let session: SessionStore
    private var requestID = UUID()
    init(service: AccountService, session: SessionStore) {
        self.service = service
        self.session = session
        super.init()
        observe(session)
        observe(service.connectivity)
    }
    /// al cambiar de cuenta no queda la lista de usuarios ni la confirmacion abierta
    func reset() {
        requestID = UUID()
        isLoading = false
        users = []
        selected = nil
        message = nil
        workingID = nil
        confirming = false
    }
    /// id propio, para no dejar que el admin se quite el rol a si mismo desde la lista
    var profileID: UUID? { session.profile?.id }
    var canUseNetwork: Bool { session.isAccountVerified && !service.connectivity.isOffline }
    /// lista de usuarios, solo si es admin
    func load() async {
        guard session.isAdmin, let userID = session.profile?.id else {
            users = []
            return
        }
        guard canUseNetwork else { return }
        let generation = session.generation, id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let values = try await service.adminUsers()
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            users = values
            message = nil
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            message = error.localizedDescription
        }
    }
    /// da o quita admin y recarga la lista
    func change(_ user: AdminUser) async {
        guard canUseNetwork, workingID == nil, let userID = session.profile?.id else { return }
        let generation = session.generation
        workingID = user.id
        defer {
            if session.matches(userID, generation: generation) {
                workingID = nil
                selected = nil
            }
        }
        do {
            try await service.setAdminRole(for: user, enabled: user.role != "admin")
            guard session.matches(userID, generation: generation) else { return }
            await load()
            guard session.matches(userID, generation: generation) else { return }
            message = "Rol actualizado. El cambio se aplicará al actualizar la cuenta del usuario."
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            message = error.localizedDescription
        }
    }
}
