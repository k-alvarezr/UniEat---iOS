import Foundation
import UniEatCore

/// Error estable del backend: {"error":{"code","message","traceId"}}. `code` decide la reacción
/// de la interfaz y `message` ya viene en español.
struct APIFailure: LocalizedError, Decodable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    private struct Envelope: Decodable { let error: APIFailure }

    static let offline = APIFailure(code: "OFFLINE", message: "Sin conexión con el servidor. Se muestra la última copia guardada.")
    static let unexpected = APIFailure(code: "INTERNAL_ERROR", message: "El servidor respondió con un error inesperado.")

    static func from(_ data: Data) -> APIFailure {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.error ?? .unexpected
    }
}

struct NoBody: Codable {}

/// Adaptador sobre la API v1 compartida: agrega `apikey` y el token del usuario, y decodifica
/// JSON camelCase con fechas ISO 8601 (el mismo decodificador de UniEatCore).
@MainActor
final class APIClient {
    private let configuration: AppConfiguration
    private let accessToken: () async throws -> String

    init(configuration: AppConfiguration, accessToken: @escaping () async throws -> String) {
        self.configuration = configuration
        self.accessToken = accessToken
    }

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send("GET", path, query: query, body: NoBody?.none)
    }

    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
                                                    query: [URLQueryItem] = [], body: Body?) async throws -> Response {
        guard let base = configuration.apiBaseURL,
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AuthFailure.unconfigured
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AuthFailure.unconfigured }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try UniEatDates.encoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIFailure.offline
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw APIFailure.unexpected }
        guard (200..<300).contains(status) else { throw APIFailure.from(data) }
        return try UniEatDates.decoder().decode(Response.self, from: data)
    }
}

// MARK: - Modelos del contrato (docs/api-v1.md en UniEat---iOS-Back)

struct FeedResponse: Codable {
    let fetchedAt: Date
    let menus: [DailyMenu]
}

struct MenusResponse: Decodable { let menus: [DailyMenu] }
struct MenuResponse: Decodable { let menu: DailyMenu }
struct CloseResponse: Decodable { let closedAt: Date }
struct ReportResponse: Decodable { let status: String }
struct BatchResponse: Decodable { let accepted: Int }

struct RemoteMembership: Decodable, Identifiable {
    let establishmentId: UUID
    let establishmentName: String
    let area: String
    let memberRole: String
    let approved: Bool
    var id: UUID { establishmentId }
}

struct MeResponse: Decodable {
    let id: UUID
    let displayName: String
    let role: String
    let establishments: [RemoteMembership]
    var profile: Profile { Profile(id: id, displayName: displayName, role: role) }
}

struct RemoteEstablishment: Decodable, Identifiable {
    let id: UUID
    let name: String
    let area: String
    let address: String
    let entranceDescription: String
    let paymentMethods: [String]
    let approved: Bool
}

struct EstablishmentsResponse: Decodable { let establishments: [RemoteEstablishment] }

struct EstablishmentRequestBody: Encodable {
    let name: String
    let area: String
    let address: String
    let entranceDescription: String
    let paymentMethods: [String]
}

struct EstablishmentRequestResponse: Decodable { let message: String }

struct PendingMembership: Decodable, Identifiable {
    let establishmentId: UUID
    let establishmentName: String
    let area: String
    let userId: UUID
    let displayName: String
    var id: String { "\(establishmentId.uuidString):\(userId.uuidString)" }
}

struct PendingMembershipsResponse: Decodable { let memberships: [PendingMembership] }

struct ApprovalBody: Encodable {
    let establishmentId: UUID
    let userId: UUID
}

struct ApprovalResponse: Decodable {
    struct Membership: Decodable { let establishmentId: UUID }
    let membership: Membership
}

struct MenuBody: Encodable {
    struct Dish: Encodable {
        let name: String
        let description: String
        let category: String
        let priceCop: Int
        let dietaryKnown: Bool
        let dietaryTags: [String]
    }

    let establishmentId: UUID?
    let title: String
    let validUntil: Date
    let paymentMethods: [String]
    let dishes: [Dish]
    let establishmentName: String
    let area: String
    let address: String?
    let entranceDescription: String
    let expectedVersion: Int?
}

struct ReportBody: Encodable {
    let publicationId: UUID
    let version: Int
    let kind: String
    let note: String
    let observedWaitMinutes: Int?
}

struct RemoteEvent: Codable, Equatable {
    let eventId: UUID
    let sessionId: UUID
    let publicationId: UUID
    let version: Int
    let kind: String
    let occurredAt: Date
}

struct EventBatch: Encodable {
    let platform = "ios"
    let events: [RemoteEvent]
}

extension FeedFilters {
    var queryItems: [URLQueryItem] {
        [("budgetCop", budgetCop.map(String.init)), ("availableMinutes", availableMinutes.map(String.init)),
         ("diet", diet), ("area", area), ("paymentMethod", paymentMethod)]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }
}
