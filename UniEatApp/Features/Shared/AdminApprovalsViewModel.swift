import Combine
import Foundation

/// estado de las solicitudes de locales que el admin aprueba, antes estaba en la vista
@MainActor
final class AdminApprovalsViewModel: FeatureViewModel {
    @Published var requests: [PendingMembership] = []
    // solicitud que se esta aprobando, para mostrar el cargando en esa fila
    @Published var workingId: String?
    @Published var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
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
    /// al cambiar de cuenta no queda la lista del admin anterior
    func reset() {
        requestID = UUID()
        isLoading = false
        hasLoaded = false
        requests = []
        message = nil
        workingId = nil
    }
    var memberships: [RemoteMembership] { session.memberships }
    var isRestaurant: Bool { session.isRestaurant }
    var canUseNetwork: Bool { session.isAccountVerified && !service.connectivity.isOffline }
    /// pide las solicitudes pendientes
    func load() async {
        guard canUseNetwork, session.isAdmin, let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let values = try await service.pendingMembershipRequests()
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            requests = values
            hasLoaded = true
            message = nil
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            message = error.localizedDescription
        }
    }
    /// aprueba y vuelve a pedir la lista, el dueño ve el cambio cuando actualiza su cuenta
    func approve(_ request: PendingMembership) async {
        guard canUseNetwork, workingId == nil, let userID = session.profile?.id else { return }
        let generation = session.generation
        workingId = request.id
        defer { if session.matches(userID, generation: generation) { workingId = nil } }
        do {
            try await service.approveMembership(request)
            guard session.matches(userID, generation: generation) else { return }
            requests.removeAll { $0.id == request.id }
            let updated = try? await service.pendingMembershipRequests()
            guard session.matches(userID, generation: generation) else { return }
            if let updated { requests = updated }
            message = "\(request.establishmentName) aprobado. El dueño debe actualizar su estado en la app."
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            message = error.localizedDescription
        }
    }
}
