import Combine
import Foundation
import UniEatCore

/// lista de Mis reportes: los restaurantes donde el usuario reporto, con el conteo por estado
/// primero pinta la copia de swiftdata y despues la cambia por la del server, que tambien se guarda
/// el filtro y la hora de la ultima sincronizacion quedan en UserDefaults por cuenta
@MainActor
final class ReportHistoryViewModel: FeatureViewModel {
    @Published private(set) var restaurants: [ReportedRestaurant] = []
    @Published private(set) var lastSyncDate: Date?          // hora del server de la ultima lista que se tiene
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageWarning: String?   // si falla leer o guardar la copia, la pantalla sigue
    /// al cambiarlo se guarda para esa cuenta, salvo cuando se esta restaurando al entrar
    @Published var filter: ReportHistoryFilter = .all {
        didSet {
            guard !restoringFilter, let userID = session.profile?.id else { return }
            preferences.saveFilter(filter, userID: userID)
        }
    }
    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let database: LocalDatabase?   // nil si la base no abrio, entonces solo red
    private let preferences: ReportHistoryPreferences
    private var requestID = UUID()   // una respuesta vieja no pisa una nueva
    private var restoringFilter = false
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         database: LocalDatabase?, preferences: ReportHistoryPreferences = ReportHistoryPreferences()) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.database = database
        self.preferences = preferences
        super.init()
        observe(connectivity)
    }
    var isOffline: Bool { connectivity.isOffline }
    /// restaurantes que pasan el filtro elegido
    var filteredRestaurants: [ReportedRestaurant] { restaurants.filter(filter.matches) }
    /// cuantos restaurantes entran en cada opcion, para mostrarlo en el chip
    func restaurantCount(matching option: ReportHistoryFilter) -> Int { restaurants.filter(option.matches).count }
    /// resumen de arriba, suma de todos los restaurantes sin importar el filtro
    var totalReports: Int { restaurants.reduce(0) { $0 + $1.total } }
    var totalConfirmed: Int { restaurants.reduce(0) { $0 + $1.confirmed } }

    /// al cambiar de cuenta se bota todo y se recupera el filtro que habia dejado la cuenta nueva
    func reset() {
        requestID = UUID()
        restaurants = []
        lastSyncDate = nil
        isLoading = false
        errorMessage = nil
        storageWarning = nil
        restoringFilter = true
        filter = session.profile.map { preferences.savedFilter(userID: $0.id) } ?? .all
        restoringFilter = false
    }

    /// copia local primero y luego el server, si cambio la sesion o arranco otra carga se bota el resultado
    func loadRestaurants() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID()
        requestID = id
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }

        // 1. lo guardado, solo la primera vez, si ya hay lista en pantalla no se vuelve a leer el disco
        if restaurants.isEmpty, let database {
            do {
                restaurants = try database.loadReportedRestaurants(userId: userID)
                lastSyncDate = preferences.lastSyncDate(userID: userID)
            } catch {
                storageWarning = "No se pudo leer la copia guardada de tus reportes."
            }
        }

        // 2. el server, sin red se queda lo guardado
        guard connectivity.isConnected else {
            if restaurants.isEmpty { errorMessage = APIFailure.offline.message }
            return
        }
        do {
            let response: ReportedRestaurantsResponse = try await api.get("me/reports/places", query: [])
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            restaurants = response.restaurants
            lastSyncDate = response.serverNow
            // se muestra antes de guardar, si falla el guardado igual se ve
            preferences.saveLastSyncDate(response.serverNow, userID: userID)
            do {
                try database?.replaceReportedRestaurants(response.restaurants, userId: userID)
            } catch {
                storageWarning = "Tus reportes se cargaron, pero no se pudo guardar la copia para verlos sin conexión."
            }
        } catch is CancellationError {
        } catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            errorMessage = error.localizedDescription
        }
    }
}
