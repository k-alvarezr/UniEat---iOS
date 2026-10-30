import Combine
import Foundation
import UniEatCore

/// One source of identity and server-derived permissions for all screens.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var memberships: [RemoteMembership] = []
    @Published private(set) var establishments: [RemoteEstablishment] = []
    @Published private(set) var accountError: String?
    @Published var authMessage: String?
    private(set) var generation = UUID()
    var onChange: (() -> Void)?
    private let auth: SessionAuthenticating
    private let api: APIRequesting
    init(auth: SessionAuthenticating, api: APIRequesting) { self.auth = auth; self.api = api }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    var isAdmin: Bool { profile?.role == "admin" }
    var approvedEstablishments: [RemoteEstablishment] { establishments.filter(\.approved) }
    func matches(_ userID: UUID, generation expected: UUID) -> Bool {
        profile?.id == userID && generation == expected
    }
    func restore() async {
        let expected = generation
        guard let restored = await auth.restore(), generation == expected else { return }
        await start(restored)
    }
    func signIn(email: String, password: String) async throws {
        let expected = generation
        let profile = try await auth.signIn(email: email, password: password)
        guard expected == generation else { throw CancellationError() }
        await start(profile)
    }
    func signUp(email: String, password: String, name: String) async throws {
        let expected = generation
        let signedIn = try await auth.signUp(email: email, password: password, name: name)
        guard expected == generation else { throw CancellationError() }
        guard let signedIn else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
            return
        }
        await start(signedIn)
    }
    private func start(_ signedIn: Profile) async {
        generation = UUID()
        profile = signedIn
        memberships = []; establishments = []; authMessage = nil; accountError = nil
        onChange?()
        do { try await refreshAccount() }
        catch is CancellationError { }
        catch { accountError = error.localizedDescription }
    }
    func refreshAccount() async throws {
        guard let userID = profile?.id else { return }
        let expected = generation
        // Preserve Juan's PR #41: the two independent reads execute concurrently.
        async let account: MeResponse = try api.get("me", query: [])
        async let owned: EstablishmentsResponse = try api.get("establishments/mine", query: [])
        let (me, mine) = try await (account, owned)
        guard matches(userID, generation: expected) else { throw CancellationError() }
        guard me.id == userID else { signOut(); throw AuthFailure.expired }
        profile = me.profile; memberships = me.establishments; establishments = mine.establishments
        accountError = nil
    }
    func signOut(message: String? = nil) {
        generation = UUID()
        auth.signOut()
        profile = nil; memberships = []; establishments = []; accountError = nil
        authMessage = message
        onChange?()
    }
    func requireAdmin() throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
    }
}
