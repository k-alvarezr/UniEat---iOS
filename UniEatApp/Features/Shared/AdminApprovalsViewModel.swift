import Combine
import Foundation

/// estado de las solicitudes de locales que el admin aprueba, antes estaba en la vista
@MainActor
final class AdminApprovalsViewModel: FeatureViewModel {
    @Published var requests: [PendingMembership] = []
    // solicitud que se esta aprobando, para mostrar el cargando en esa fila
    @Published var workingId: String?
    @Published var message: String?
    private let service: AccountService
    private let session: SessionStore
    init(service: AccountService, session: SessionStore) {
        self.service = service
        self.session = session
        super.init()
        observe(session)
    }
    /// al cambiar de cuenta no queda la lista del admin anterior
    func reset() {
        requests = []
        message = nil
        workingId = nil
    }
    var memberships: [RemoteMembership] { session.memberships }
    var isRestaurant: Bool { session.isRestaurant }
    /// pide las solicitudes pendientes
    func load() async {
        do {
            requests = try await service.pendingMembershipRequests()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
    /// aprueba y vuelve a pedir la lista, el dueño ve el cambio cuando actualiza su cuenta
    func approve(_ request: PendingMembership) async {
        workingId = request.id
        defer { workingId = nil }
        do {
            try await service.approveMembership(request)
            requests.removeAll { $0.id == request.id }
            if let updated = try? await service.pendingMembershipRequests() { requests = updated }
            message = "\(request.establishmentName) aprobado. El dueño debe actualizar su estado en la app."
        } catch {
            message = error.localizedDescription
        }
    }
}
