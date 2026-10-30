import Foundation

/// llamadas de locales y roles que antes estaban en el AppStore viejo
/// pedir un local, aprobar solicitudes y dar o quitar admin, las de admin revisan el rol antes de llamar
@MainActor
final class AccountService {
    let session: SessionStore
    let connectivity: ConnectivityService
    private let api: APIRequesting
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
    }
    private func requireConnection() throws {
        guard !connectivity.isOffline else {
            throw APIFailure(code: "OFFLINE", message: "Esta acción requiere conexión. Los datos locales no cambian permisos ni confirman solicitudes.")
        }
    }
    /// pide un local nuevo, queda pendiente hasta que un admin lo apruebe
    /// si falla recargar la cuenta no importa, la solicitud ya se creo
    func requestEstablishment(_ body: EstablishmentRequestBody) async throws {
        try requireConnection()
        let _: EstablishmentRequestResponse = try await api.send("POST", "establishments", body: body)
        try? await session.refreshAccount()
    }
    /// admin: solicitudes de locales que faltan por aprobar
    func pendingMembershipRequests() async throws -> [PendingMembership] {
        try session.requireAdmin()
        try requireConnection()
        let result: PendingMembershipsResponse = try await api.get("admin/memberships", query: [.init(name: "status", value: "pending")])
        return result.memberships
    }
    /// admin: aprueba un local, ese usuario pasa a ser restaurante
    func approveMembership(_ request: PendingMembership) async throws {
        try session.requireAdmin()
        try requireConnection()
        let _: ApprovalResponse = try await api.send("POST", "admin/memberships/approve",
            body: ApprovalBody(establishmentId: request.establishmentId, userId: request.userId))
    }
    /// admin: lista de usuarios con su rol
    func adminUsers() async throws -> [AdminUser] {
        try session.requireAdmin()
        try requireConnection()
        let response: AdminUsersResponse = try await api.get("admin/users")
        return response.users
    }
    /// admin: da o quita el rol de admin a otro usuario
    func setAdminRole(for user: AdminUser, enabled: Bool) async throws {
        try session.requireAdmin()
        try requireConnection()
        let _: AdminRoleResponse = try await api.send("PATCH", "admin/users/\(user.id.uuidString)/role",
            body: AdminRoleBody(role: enabled ? "admin" : "student"))
    }
}
