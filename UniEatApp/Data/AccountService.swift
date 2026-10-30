import Foundation

@MainActor
final class AccountService {
    let session: SessionStore
    private let api: APIRequesting
    init(api: APIRequesting, session: SessionStore) { self.api = api; self.session = session }
    func requestEstablishment(_ body: EstablishmentRequestBody) async throws {
        let _: EstablishmentRequestResponse = try await api.send("POST", "establishments", body: body)
        try? await session.refreshAccount()
    }
    func pendingMembershipRequests() async throws -> [PendingMembership] {
        try session.requireAdmin()
        let result: PendingMembershipsResponse = try await api.get("admin/memberships", query: [.init(name: "status", value: "pending")])
        return result.memberships
    }
    func approveMembership(_ request: PendingMembership) async throws {
        try session.requireAdmin()
        let _: ApprovalResponse = try await api.send("POST", "admin/memberships/approve",
            body: ApprovalBody(establishmentId: request.establishmentId, userId: request.userId))
    }
    func adminUsers() async throws -> [AdminUser] {
        try session.requireAdmin()
        let response: AdminUsersResponse = try await api.get("admin/users")
        return response.users
    }
    func setAdminRole(for user: AdminUser, enabled: Bool) async throws {
        try session.requireAdmin()
        let _: AdminRoleResponse = try await api.send("PATCH", "admin/users/\(user.id.uuidString)/role",
            body: AdminRoleBody(role: enabled ? "admin" : "student"))
    }
}
