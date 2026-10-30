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
    @Published private(set) var isForgetting = false
    /// Una cuenta guardada permite navegar y editar borradores, nunca conceder permisos sin verificar.
    @Published private(set) var isAccountVerified = false
    @Published private(set) var cachedAccountDate: Date?
    /// id de esta sesion, cambia al entrar o salir
    /// las tareas guardan la generacion con la que arrancaron y si al terminar es otra botan el resultado
    /// asi una respuesta vieja nunca le llega al usuario siguiente
    private(set) var generation = UUID()
    var onChange: (() -> Void)?            // lo pone AppStore, se llama cuando entra o sale alguien
    var onForget: ((UUID, UUID) async throws -> Void)? // usuario y generación que se van a limpiar
    private let auth: SessionAuthenticating
    private let api: APIRequesting
    init(auth: SessionAuthenticating, api: APIRequesting) {
        self.auth = auth
        self.api = api
    }
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
        guard !isForgetting else { return }
        let expected = generation
        guard let restored = await auth.restore(), generation == expected else { return }
        await start(restored)
    }
    /// login con correo y contraseña, si alguien mas entro o salio mientras tanto se cancela
    func signIn(email: String, password: String) async throws {
        try requireCleanupFinished()
        let expected = generation
        let profile = try await auth.signIn(email: email, password: password)
        guard expected == generation else { throw CancellationError() }
        await start(profile)
    }
    /// crea la cuenta, si supabase pide confirmar el correo no hay sesion todavia y se avisa
    func signUp(email: String, password: String, name: String) async throws {
        try requireCleanupFinished()
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
        let cached = LocalValues.load(CachedAccountSnapshot.self, key: Self.accountCacheKey(signedIn.id))
        if let cached, cached.profile.id == signedIn.id {
            profile = cached.profile
            memberships = cached.memberships
            establishments = cached.establishments
            cachedAccountDate = cached.savedAt
        } else {
            profile = signedIn
            memberships = []
            establishments = []
            cachedAccountDate = nil
        }
        isAccountVerified = false
        authMessage = nil
        accountError = nil
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
        guard me.id == userID else {
            signOut()
            throw AuthFailure.expired
        }
        profile = me.profile
        memberships = me.establishments
        establishments = mine.establishments
        isAccountVerified = true
        let savedAt = Date()
        cachedAccountDate = savedAt
        LocalValues.save(CachedAccountSnapshot(profile: me.profile, memberships: me.establishments,
            establishments: mine.establishments, savedAt: savedAt), key: Self.accountCacheKey(userID))
        accountError = nil
    }
    /// cierra sesion: generacion nueva para cortar lo que estaba en camino, borra el keychain y limpia todo
    /// El vencimiento automático conserva pendientes. El cierre manual usa signOutAndForget.
    func signOut(message: String? = nil) {
        generation = UUID()
        auth.signOut()
        profile = nil
        memberships = []
        establishments = []
        isAccountVerified = false
        cachedAccountDate = nil
        accountError = nil
        authMessage = message
        onChange?()
    }
    /// Invalida primero las tareas de la cuenta y espera su limpieza antes de permitir otro login.
    /// Así una escritura vieja no puede reaparecer después de borrar, ni se limpia otra sesión.
    func signOutAndForget() async {
        guard !isForgetting, let leaving = profile?.id else { return }
        let departingGeneration = generation
        LocalValues.remove(key: Self.accountCacheKey(leaving))
        isForgetting = true
        signOut()
        defer { isForgetting = false }
        do {
            try await onForget?(leaving, departingGeneration)
        } catch {
            authMessage = "Cerraste sesión, pero no se pudieron limpiar todos los datos locales. Se conservaron los que no pudieron borrarse; vuelve a entrar para intentarlo de nuevo."
        }
    }
    private func requireCleanupFinished() throws {
        guard !isForgetting else {
            throw APIFailure(code: "LOCAL_STORAGE_BUSY", message: "Estamos terminando de cerrar la sesión. Espera un momento.")
        }
    }
    /// corta antes de llamar si no es admin, igual el server lo vuelve a revisar
    func requireAdmin() throws {
        guard isAdmin else { throw APIFailure(code: "FORBIDDEN", message: "Solo administradores.") }
        try requireVerifiedAccount()
    }

    func requireVerifiedAccount() throws {
        guard isAccountVerified else {
            throw APIFailure(code: "OFFLINE", message: "Actualiza tu cuenta con conexión antes de cambiar permisos o publicaciones.")
        }
    }

    static func accountCacheKey(_ userID: UUID) -> String { "unieat.account.v1.\(userID.uuidString)" }
}

/// Datos de presentación recibidos de /me; no contiene tokens ni se usa como autorización del backend.
struct CachedAccountSnapshot: Codable {
    let profile: Profile
    let memberships: [RemoteMembership]
    let establishments: [RemoteEstablishment]
    let savedAt: Date
}
