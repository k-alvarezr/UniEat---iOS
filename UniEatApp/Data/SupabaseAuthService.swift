import Foundation
import Security
import UniEatCore

enum AuthFailure: LocalizedError {
    case expired
    case unconfigured
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .expired: return "Tu sesión terminó. Inicia sesión de nuevo."
        case .unconfigured: return "Configura Supabase en BackendConfig.json para usar una cuenta real."
        case .invalidResponse: return "El servicio de autenticación devolvió una respuesta inesperada."
        case .service(let message): return message
        }
    }
}

private struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String
    let profile: Profile
    /// es opcional para que las sesiones viejas sigan funcionando
    let expiresAt: Date?
}

@MainActor
final class SupabaseAuthService {
    private(set) var generation = UUID()
    private let config = AppConfiguration.current
    private let keychainService = "co.edu.uniandes.unieat.auth"

    func signIn(email: String, password: String) async throws -> Profile {
        let expected = generation
        let data = try await request(path: "auth/v1/token", query: "grant_type=password",
                                     body: ["email": email, "password": password])
        guard let session = try session(from: data) else { throw AuthFailure.invalidResponse }
        guard generation == expected else { throw CancellationError() }
        store(session)
        return session.profile
    }

    func signUp(email: String, password: String, name: String) async throws -> Profile? {
        let expected = generation
        if let error = RegistrationRules.nameError(name) ?? RegistrationRules.passwordError(password) {
            throw AuthFailure.service(error)
        }
        let data = try await request(path: "auth/v1/signup", body: [
            "email": email, "password": password,
            "data": ["display_name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        ])
        guard let session = try session(from: data) else { return nil }
        guard generation == expected else { throw CancellationError() }
        store(session)
        return session.profile
    }

    func restore() async -> Profile? {
        guard config.isConfigured,
              let data = keychainData(),
              let cached = try? JSONDecoder().decode(StoredSession.self, from: data) else { return nil }
        do {
            return try await refresh(cached).profile
        } catch is URLError {
            // si abre sin internet se deja la sesion para seguir mostrando el feed guardado
            return cached.profile
        } catch is CancellationError {
            return nil
        } catch AuthFailure.expired {
            signOut()
            return nil
        } catch {
            // A temporary Auth outage must not destroy the device's cached session.
            return cached.profile
        }
    }

    /// token para llamar a la api, se renueva un minuto antes de que venza
    func validAccessToken() async throws -> String {
        guard let data = keychainData(),
              let cached = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            throw AuthFailure.expired
        }
        if let expiresAt = cached.expiresAt, expiresAt > .now.addingTimeInterval(60) {
            return cached.accessToken
        }
        return try await refresh(cached).accessToken
    }

    // si ya se esta renovando, las demas llamadas esperan esa misma renovacion
    private var renewing: Task<StoredSession, Error>?

    private func refresh(_ cached: StoredSession) async throws -> StoredSession {
        if let renewing { return try await renewing.value }
        let expected = generation
        let task = Task {
            let response = try await request(path: "auth/v1/token", query: "grant_type=refresh_token",
                                             body: ["refresh_token": cached.refreshToken])
            guard let renewed = try session(from: response) else { throw AuthFailure.invalidResponse }
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            store(renewed)
            return renewed
        }
        renewing = task
        defer { renewing = nil }
        return try await task.value
    }

    func signOut() {
        generation = UUID()
        renewing?.cancel()
        renewing = nil
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary)
    }

    /// POST a supabase auth, devuelve la respuesta o lanza el error ya traducido al español
    private func request(path: String, query: String? = nil, body: [String: Any]) async throws -> Data {
        // 1. armar la url: url de supabase + ruta + parametros
        guard config.isConfigured,
              let base = URL(string: config.supabaseURL),
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AuthFailure.unconfigured
        }
        if let query { components.query = query }
        guard let url = components.url else { throw AuthFailure.unconfigured }

        // 2. armar la peticion: siempre POST con json
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 3. enviarla y revisar la respuesta
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (details?["error_code"] as? String) ?? (details?["code"] as? String) ?? ""
            if ["refresh_token_not_found", "refresh_token_already_used", "session_not_found", "bad_jwt"].contains(code) {
                throw AuthFailure.expired
            }
            throw AuthFailure.service(errorMessage(from: data, status: http.statusCode))
        }
        return data
    }

    /// pasa el error de supabase a un mensaje en español para mostrarle al usuario
    private func errorMessage(from data: Data, status: Int) -> String {
        // supabase manda el codigo en error_code o en code segun la version
        let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (details?["error_code"] as? String) ?? (details?["code"] as? String) ?? ""

        switch code {
        case "invalid_credentials": return "Correo o contraseña incorrectos."
        case "email_not_confirmed": return "Confirma tu correo antes de iniciar sesión."
        case "user_already_exists", "email_exists": return "Ya existe una cuenta con este correo."
        case "weak_password": return "La contraseña no cumple los requisitos de seguridad."
        default:
            if status == 429 { return "Demasiados intentos. Espera un momento y vuelve a probar." }
            return "No se pudo completar la autenticación. Revisa tus datos e inténtalo de nuevo."
        }
    }

    /// arma la sesion desde la respuesta de supabase, nil si todavia no hay tokens, confirmacion de correo desactivada en SupaBase
    private func session(from data: Data) throws -> StoredSession? {
        // el usuario tiene que venir si o si, si no la respuesta esta mal
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              let idText = user["id"] as? String,
              let id = UUID(uuidString: idText) else { throw AuthFailure.invalidResponse }

        // sin tokens no hay sesion todavia, pasa al crear cuenta si hay que confirmar el correo
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return nil }

        // el nombre sale de los datos del registro, si no hay se usa el correo
        let metadata = user["user_metadata"] as? [String: Any]
        let email = user["email"] as? String ?? ""
        let name = metadata?["display_name"] as? String ?? email

        // supabase manda el vencimiento como fecha (expires_at) o como segundos que faltan (expires_in)
        let expiresAt = (json["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (json["expires_in"] as? Double).map { Date.now.addingTimeInterval($0) }

        // el rol siempre empieza como estudiante, el real llega despues con /me
        let profile = Profile(id: id, displayName: name, role: "student")
        return StoredSession(accessToken: access, refreshToken: refresh, profile: profile, expiresAt: expiresAt)
    }

    /// guarda la sesion en el keychain, si ya habia una la reemplaza
    private func store(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let sessionQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: keychainService,
                                           kSecAttrAccount as String: "session"]

        // si ya hay una sesion guardada se actualiza, asi nunca queda un momento sin sesion
        let updated = SecItemUpdate(sessionQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecItemNotFound { return }

        // si no habia, se crea, solo para este celular y despues del primer desbloqueo
        var newItem = sessionQuery
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(newItem as CFDictionary, nil)
    }

    /// lee la sesion guardada en el keychain, nil si no hay
    private func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,   // tipo: una contraseña generica
            kSecAttrService as String: keychainService,      // del cajon de unieat
            kSecAttrAccount as String: "session",            // el registro llamado "session"
            kSecReturnData as String: true,                  // devuelveme el contenido
            kSecMatchLimit as String: kSecMatchLimitOne      // solo uno
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
