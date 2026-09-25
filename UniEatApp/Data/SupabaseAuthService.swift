import Foundation
import Security
import UniEatCore

enum AuthFailure: LocalizedError {
    case unconfigured
    case invalidResponse
    case service(String)

    var errorDescription: String? {
        switch self {
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
}

@MainActor
final class SupabaseAuthService {
    private let config = AppConfiguration.current
    private let keychainService = "co.edu.uniandes.unieat.auth"

    func signIn(email: String, password: String) async throws -> Profile {
        let data = try await request(path: "auth/v1/token", query: "grant_type=password",
                                     body: ["email": email, "password": password])
        guard let session = try session(from: data) else { throw AuthFailure.invalidResponse }
        store(session)
        return session.profile
    }

    func signUp(email: String, password: String, name: String, role: String) async throws -> Profile? {
        let data = try await request(path: "auth/v1/signup", body: [
            "email": email, "password": password,
            "data": ["display_name": name, "role": role]
        ])
        guard let session = try session(from: data) else { return nil }
        store(session)
        return session.profile
    }

    func restore() async -> Profile? {
        guard config.isConfigured,
              let data = keychainData(),
              let cached = try? JSONDecoder().decode(StoredSession.self, from: data) else { return nil }
        do {
            let response = try await request(path: "auth/v1/token", query: "grant_type=refresh_token",
                                             body: ["refresh_token": cached.refreshToken])
            guard let renewed = try session(from: response) else { return nil }
            store(renewed)
            return renewed.profile
        } catch {
            signOut()
            return nil
        }
    }

    func signOut() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary)
    }

    private func request(path: String, query: String? = nil, body: [String: Any]) async throws -> Data {
        guard config.isConfigured,
              let base = URL(string: config.supabaseURL),
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AuthFailure.unconfigured
        }
        if let query { components.query = query }
        guard let url = components.url else { throw AuthFailure.unconfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (details?["msg"] as? String) ??
                          (details?["error_description"] as? String) ??
                          "No se pudo completar la autenticación."
            throw AuthFailure.service(message)
        }
        return data
    }

    private func session(from data: Data) throws -> StoredSession? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              let idText = user["id"] as? String,
              let id = UUID(uuidString: idText) else { throw AuthFailure.invalidResponse }
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else { return nil }
        let metadata = user["user_metadata"] as? [String: Any]
        let email = user["email"] as? String ?? ""
        let name = metadata?["display_name"] as? String ?? email
        let role = metadata?["role"] as? String == "restaurant" ? "restaurant" : "student"
        return StoredSession(accessToken: access, refreshToken: refresh,
                             profile: Profile(id: id, displayName: name, role: role))
    }

    private func store(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        signOut()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "session",
                                    kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainData() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "session",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
