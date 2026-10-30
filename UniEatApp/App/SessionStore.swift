import Combine
import Foundation
import UniEatCore

/// la sesion sale del AppStore viejo a su propia clase
/// es la unica fuente de quien entro, su rol y sus locales, todas las pantallas la leen de aca
/// el rol siempre sale del server (GET /me), nunca se decide en el celular
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var profile: Profile?                          // quien entro, nil es que no hay sesion
    @Published private(set) var memberships: [RemoteMembership] = []       // locales del usuario y si estan aprobados
    @Published private(set) var establishments: [RemoteEstablishment] = [] // datos de esos locales
    @Published private(set) var accountError: String?                      // error al cargar la cuenta
    @Published var authMessage: String?                                    // aviso en el login, ej confirmar correo
    /// id de esta sesion, cambia al entrar o salir
    /// las tareas guardan la generacion con la que arrancaron y si al terminar es otra botan el resultado
    /// asi una respuesta vieja nunca le llega al usuario siguiente
    private(set) var generation = UUID()
    var onChange: (() -> Void)?            // lo pone AppStore, se llama cuando entra o sale alguien
    private let auth: SessionAuthenticating
    private let api: APIRequesting
    init(auth: SessionAuthenticating, api: APIRequesting) { self.auth = auth; self.api = api }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    var isAdmin: Bool { profile?.role == "admin" }
    /// solo los locales que un admin ya aprobo, con esos se puede publicar
    var approvedEstablishments: [RemoteEstablishment] { establishments.filter(\.approved) }
    /// true si sigue siendo el mismo usuario y la misma sesion con la que arranco una tarea
    func matches(_ userID: UUID, generation expected: UUID) -> Bool {
        profile?.id == userID && generation == expected
    }
    /// si habia sesion en el keychain se entra directo
    func restore() async {
        let expected = generation
        guard let restored = await auth.restore(), generation == expected else { return }
        await start(restored)
    }
    /// login con correo y contraseña, si alguien mas entro o salio mientras tanto se cancela
    func signIn(email: String, password: String) async throws {
        let expected = generation
        let profile = try await auth.signIn(email: email, password: password)
        guard expected == generation else { throw CancellationError() }
        await start(profile)
    }
    /// crea la cuenta, si supabase pide confirmar el correo no hay sesion todavia y se avisa
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
    // arranca la sesion: generacion nueva, limpia lo anterior, avisa a AppStore y pide la cuenta al server
    private func start(_ signedIn: Profile) async {
        generation = UUID()
        profile = signedIn
        memberships = []; establishments = []; authMessage = nil; accountError = nil
        onChange?()
        do { try await refreshAccount() }
        catch is CancellationError { }
        catch { accountError = error.localizedDescription }
    }
    /// pide quien es el usuario y sus locales, las dos no dependen una de la otra
    /// entonces van en paralelo con async let (#31), si una falla la otra se cancela sola
    func refreshAccount() async throws {
        guard let userID = profile?.id else { return }
        let expected = generation
        async let account: MeResponse = try api.get("me", query: [])
        async let owned: EstablishmentsResponse = try api.get("establishments/mine", query: [])
        let (me, mine) = try await (account, owned)
        // si mientras tanto cambio la sesion se bota la respuesta
        guard matches(userID, generation: expected) else { throw CancellationError() }
        // si el server dice que es otro usuario se cierra la sesion por seguridad
        guard me.id == userID else { signOut(); throw AuthFailure.expired }
        profile = me.profile; memberships = me.establishments; establishments = mine.establishments
        accountError = nil
    }
    /// cierra sesion: generacion nueva para cortar lo que estaba en camino, borra el keychain y limpia todo
    /// ya no borra reportes, detalles ni borrador, quedan guardados por usuario para cuando vuelva
    func signOut(message: String? = nil) {
        generation = UUID()
        auth.signOut()
        profile = nil; memberships = []; establishments = []; accountError = nil
        authMessage = message
        onChange?()
    }
    /// corta antes de llamar si no es admin, igual el server lo vuelve a revisar
    func requireAdmin() throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
    }
}
