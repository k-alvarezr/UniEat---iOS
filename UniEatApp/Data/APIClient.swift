import Foundation
import UniEatCore

// MARK: - errores

/// error que manda el back con code y message, code dice que hace la pantalla
/// y message ya viene en español
struct APIFailure: LocalizedError, Decodable {
    let code: String
    let message: String

    var errorDescription: String? { message }

    private struct Envelope: Decodable { let error: APIFailure }

    static let offline = APIFailure(code: "OFFLINE", message: "Sin conexión con el servidor. Se muestra la última copia guardada.")
    static let unexpected = APIFailure(code: "INTERNAL_ERROR", message: "El servidor respondió con un error inesperado.")
    static let invalidResponse = APIFailure(code: "INVALID_RESPONSE", message: "La app no entendio la respuesta del servidor. Actualiza la app e intenta de nuevo.")

    static func from(_ data: Data) -> APIFailure {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.error ?? .unexpected
    }
}

// cuerpo vacio para los get, que no mandan nada
struct NoBody: Codable {}

@MainActor
protocol APIRequesting: AnyObject, Sendable {
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String,
        query: [URLQueryItem], body: Body?) async throws -> Response
}

extension APIRequesting {
    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await get(path, query: [])
    }
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        try await send(method, path, query: [], body: body)
    }
}

// MARK: - cliente

/// adapter de la api v1, pone la apikey y el token del usuario y lee el json
/// con las fechas igual que UniEatCore
@MainActor
final class APIClient: APIRequesting {
    private let configuration: AppConfiguration
    // funcion que entrega un token valido, la pone AppStore con auth.validAccessToken()
    private let accessToken: () async throws -> String
    private let sessionIdentity: () -> UUID
    private let transport: URLSession
    var onUnauthorized: (() -> Void)?

    /// Authenticated JSON must never be replayed from a URL-only shared HTTP cache.
    private static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    init(configuration: AppConfiguration, session: URLSession = APIClient.uncachedSession,
         sessionIdentity: @escaping () -> UUID = { UUID.zero },
         accessToken: @escaping () async throws -> String) {
        self.configuration = configuration
        transport = session
        self.sessionIdentity = sessionIdentity
        self.accessToken = accessToken
    }

    /// pedir algo al server, sin cuerpo
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send("GET", path, query: query, body: NoBody?.none)
    }

    /// mandar una peticion con metodo, ruta, parametros y cuerpo opcional
    /// devuelve la respuesta ya convertida al tipo que se pidio
    func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Body?) async throws -> Response {
        let identity = sessionIdentity()
        try Task.checkCancellation()
        
        // 1. armar la url: base de la api + ruta + parametros
        // components toma toda la url y la divide en piezas
        // https//x/functions/v1/api-v1/feed -> scheme: https, host: x, path: /functions/v1/api-v1/feed
        guard let base = configuration.apiBaseURL,
              var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AuthFailure.unconfigured
        }
        // se añaden parametros si los hay: [URLQueryItem(name: "area", value: "Centro"), …]
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AuthFailure.unconfigured }

        // 2. armar la peticion
        var request = URLRequest(url: url, timeoutInterval: 20)   // si en 20 segundos no responde, falla
        request.httpMethod = method                               // GET, POST, PUT, PATCH...

        // cabeceras que pide el server en todas las llamadas
        let token: String
        do { token = try await accessToken() }
        catch AuthFailure.expired { onUnauthorized?(); throw AuthFailure.expired }
        guard identity == sessionIdentity() else { throw CancellationError() }
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")  // clave publica del proyecto supabase
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")      // quien es el usuario
        request.setValue("ios", forHTTPHeaderField: "X-UniEat-Platform")              // para separar metricas de ios y android

        // si hay algo que mandar, va como json
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")  // le dice al server que es json
            request.httpBody = try UniEatDates.encoder().encode(body)                 // el cuerpo convertido a json
        }

        // 3. enviarla, si no hay respuesta es porque no hay internet
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIFailure.offline
        }
        try Task.checkCancellation()
        guard identity == sessionIdentity() else { throw CancellationError() }

        // 4. revisar la respuesta: si no es 2xx se lee el error del server, si esta bien se convierte
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw APIFailure.unexpected }
        guard (200..<300).contains(status) else {
            if status == 401 { onUnauthorized?() }
            throw APIFailure.from(data)
        }
        do {
            return try UniEatDates.decoder().decode(Response.self, from: data)
        } catch {
            // el server respondio bien pero el json no calza con lo que espera la app,
            // pasa si el back cambio el contrato y la app no se actualizo
            throw APIFailure.invalidResponse
        }
    }
}

// MARK: - modelos de la api, ver docs/api-v1.md en el back

// MARK: - feed

/// respuesta del feed, los menus de hoy y la hora en que el server los mando, tambien se guarda como copia sin internet
struct FeedResponse: Codable, Sendable {
    let fetchedAt: Date
    let menus: [DailyMenu]
    var serverNow: Date? = nil
}

/// Convierte los filtros en parametros de la URL y omite los vacios
extension FeedFilters {
    var queryItems: [URLQueryItem] {
        [("budgetCop", budgetCop.map(String.init)), ("availableMinutes", availableMinutes.map(String.init)),
         ("diet", diet), ("area", area), ("paymentMethod", paymentMethod)]
            .compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    }
}

// MARK: - menus: lista, detalle, publicar y cerrar

/// lista de menus, la usa menus/mine para los menus del restaurante
struct MenusResponse: Decodable { let menus: [DailyMenu] }
/// un menu solo, lo devuelve el server al publicar o editar
struct MenuResponse: Decodable { let menu: DailyMenu }

/// lo que se manda al publicar o editar un menu
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

/// respuesta al cerrar un menu, la hora en que quedo cerrado
struct CloseResponse: Decodable { let closedAt: Date }

// MARK: - reportes

/// lo que se manda al reportar un cambio, va con la version que vio el estudiante
struct ReportBody: Encodable, Sendable {
    let publicationId: UUID
    let version: Int
    let kind: String
    let note: String
    let observedWaitMinutes: Int?
    var clientReportId: UUID? = nil
    var observedAt: Date? = nil
}

/// respuesta al reportar, el estado en que quedo pending confirmed u observation
struct ReportResponse: Decodable, Sendable { let status: String }

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

// MARK: - eventos de analitica

/// un evento de analitica, tipo abrir detalle o guardar, el id lo crea el celular para no contar doble
struct RemoteEvent: Codable, Equatable {
    let eventId: UUID
    let sessionId: UUID
    let publicationId: UUID
    let version: Int
    let kind: String
    let occurredAt: Date
    var metadata: ExperimentEventMetadata? = nil
}

/// un lote de eventos para mandarlos juntos, hasta 100
struct EventBatch: Encodable {
    let platform = "ios"
    let events: [RemoteEvent]
}

/// respuesta del lote, cuantos eventos acepto el server
struct BatchResponse: Decodable { let accepted: Int }

// MARK: - cuenta y locales

/// respuesta de /me, quien es el usuario, su rol real y sus locales
struct MeResponse: Decodable {
    let id: UUID
    let displayName: String
    let role: String
    let establishments: [RemoteMembership]
    var profile: Profile { Profile(id: id, displayName: displayName, role: role) }
}

/// un local del usuario y si ya esta aprobado para publicar
struct RemoteMembership: Decodable, Identifiable {
    let establishmentId: UUID
    let establishmentName: String
    let area: String
    let memberRole: String
    let approved: Bool
    var id: UUID { establishmentId }
}

/// los datos de un local del usuario
struct RemoteEstablishment: Decodable, Identifiable {
    let id: UUID
    let name: String
    let area: String
    let address: String
    let entranceDescription: String
    let paymentMethods: [String]
    let approved: Bool
}

/// lista de locales del usuario
struct EstablishmentsResponse: Decodable { let establishments: [RemoteEstablishment] }

/// lo que se manda al pedir un local nuevo, con el pin si lo hay
struct EstablishmentRequestBody: Encodable {
    let name: String
    let area: String
    let address: String
    let entranceDescription: String
    let paymentMethods: [String]
    let photoUrl: String?
    /// pin del local, sale de la direccion o del gps y se confirma en el mapa
    let latitude: Double?
    let longitude: Double?
}

/// respuesta al pedir un local, un mensaje del server
struct EstablishmentRequestResponse: Decodable { let message: String }

// MARK: - admin: aprobar locales y roles

/// una solicitud de local que el admin todavia no aprueba
struct PendingMembership: Decodable, Identifiable {
    let establishmentId: UUID
    let establishmentName: String
    let area: String
    let userId: UUID
    let displayName: String
    var id: String { "\(establishmentId.uuidString):\(userId.uuidString)" }
}

/// lista de solicitudes pendientes para el admin
struct PendingMembershipsResponse: Decodable { let memberships: [PendingMembership] }

/// lo que manda el admin para aprobar un local, que local y que usuario
struct ApprovalBody: Encodable {
    let establishmentId: UUID
    let userId: UUID
}

/// respuesta al aprobar un local
struct ApprovalResponse: Decodable {
    struct Membership: Decodable { let establishmentId: UUID }
    let membership: Membership
}

/// un usuario en la lista del admin, con su rol
struct AdminUser: Decodable, Identifiable {
    let id: UUID
    let displayName: String
    let role: String
}

/// lista de usuarios para el admin
struct AdminUsersResponse: Decodable { let users: [AdminUser] }
/// lo que manda el admin para dar o quitar el rol de admin
struct AdminRoleBody: Encodable { let role: String }
/// respuesta al cambiar el rol, el usuario y su rol nuevo
struct AdminRoleResponse: Decodable { let id: UUID; let role: String }

// MARK: - panel de rendimiento

/// todo lo del panel de rendimiento en un periodo, BQ-03 BQ-04 y actividad
struct AdminDashboardSnapshot: Decodable {
    let periodDays: Int
    let generatedAt: Date
    let platform: String
    let bq03: BQ03Metrics
    let bq04: BQ04Metrics
    let engagement: PerformanceSummary
    var bq08: BQ08Metrics? = nil
}

struct BQ08Metrics: Decodable {
    struct Groups: Decodable { let control: Group; let treatment: Group }
    struct Group: Decodable {
        let assignedSessions: Int
        let exposedSessions: Int
        let initialSelections: Int
        let completeSelections: Int
        let incompleteSelections: Int
        let longLineOutcomes: Int
        let switchOutcomes: Int
        let combinedOutcomes: Int
        let outcomeRate: Double?
    }
    let groups: Groups
    let insufficientData: Bool
    let rateDifference: Double?
    let followUpMinutes: Int
    let minimumSampleSize: Int
}

/// cifras de BQ-03, cuantas veces se pidio el feed y como le fue
struct BQ03Metrics: Decodable {
    let feedRequests: Int
    let successfulRequests: Int
    let failedRequests: Int
    let zeroResultRequests: Int
    let contextualRequests: Int
    let averageResults: Double
}

/// cifras de BQ-04, cuantos detalles se abrieron y en que estado estaban
struct BQ04Metrics: Decodable {
    let detailRequests: Int
    let activeShown: Int
    let expiringShown: Int
    let expiredShown: Int
    let closedShown: Int
    let pendingNoticesShown: Int
    let confirmedNoticesShown: Int
}
