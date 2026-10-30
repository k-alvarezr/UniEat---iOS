import Combine
import CoreLocation
import MapKit
import Foundation

@MainActor
final class AdminApprovalsViewModel: FeatureViewModel {
    @Published var requests: [PendingMembership] = []
    @Published var workingId: String?
    @Published var message: String?
    private let service: AccountService
    private let session: SessionStore
    init(service: AccountService, session: SessionStore) {
        self.service = service; self.session = session; super.init(); observe(session)
    }
    var memberships: [RemoteMembership] { session.memberships }
    var isRestaurant: Bool { session.isRestaurant }
    func load() async {
        do {
            requests = try await service.pendingMembershipRequests()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
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

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
