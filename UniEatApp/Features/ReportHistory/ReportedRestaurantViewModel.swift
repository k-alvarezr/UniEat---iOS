import Combine
import Foundation
import UniEatCore

/// detalle de un restaurante en Mis reportes, uno por cada vez que se abre (como el detalle del menu)
/// busca en este orden: memoria (LRU de los 2 ultimos) -> copia de swiftdata -> server
/// lo que llega del server se guarda en la base y en la memoria
@MainActor
final class ReportedRestaurantViewModel: FeatureViewModel {
    @Published private(set) var restaurant: ReportedRestaurant
    @Published private(set) var reports: [UserReport] = []
    @Published private(set) var lastSyncDate: Date?          // hora del server de la copia que se muestra
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageWarning: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let database: LocalDatabase?
    private let memory: ReportedRestaurantMemoryCache   // ultimos 2 restaurantes abiertos, compartida por todos los detalles
    private let preferences = ReportHistoryPreferences()
    private var requestID = UUID()
    /// arranca con el resumen de la lista para pintar el encabezado sin esperar disco ni red
    init(restaurant: ReportedRestaurant, api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         database: LocalDatabase?, memory: ReportedRestaurantMemoryCache) {
        self.restaurant = restaurant
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.database = database
        self.memory = memory
        super.init()
        observe(connectivity)
    }
    var isOffline: Bool { connectivity.isOffline }
    var isConnected: Bool { connectivity.isConnected }
    /// recien abierto (o sin nada que mostrar): vale la pena buscar algo rapido antes del server
    /// es calculada, asi si la memoria ya lleno la pantalla el paso de la base se salta
    private var nothingOnScreenYet: Bool { reports.isEmpty }

    func loadReports() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID(), establishmentID = restaurant.establishmentId
        requestID = id
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }

        // 1. memoria: si se abrio hace poco sale al instante, sin leer la base
        if nothingOnScreenYet, let recent = memory.value(userID: userID, establishmentID: establishmentID) {
            show(recent)
        }
        // 2. lo guardado en la base, si no estaba en memoria
        if nothingOnScreenYet, let database {
            do {
                let saved = try database.loadUserReports(userId: userID, establishmentId: establishmentID)
                if !saved.isEmpty {
                    // la copia es de la ultima sincronizacion de Mis reportes
                    let snapshot = ReportedRestaurantSnapshot(restaurant: restaurant, reports: saved,
                                                              lastSyncDate: preferences.lastSyncDate(userID: userID))
                    show(snapshot)
                    memory.insert(snapshot, userID: userID)
                }
            } catch {
                storageWarning = "No se pudo leer la copia guardada de este restaurante."
            }
        }

        // 3. el server, sin red se queda lo que ya se mostro
        guard connectivity.isConnected else {
            if nothingOnScreenYet { errorMessage = APIFailure.offline.message }
            return
        }
        do {
            let response: ReportedRestaurantDetailResponse = try await api.get("me/reports/places/\(establishmentID.uuidString)", query: [])
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            let fresh = ReportedRestaurantSnapshot(restaurant: response.restaurant, reports: response.reports,
                                                   lastSyncDate: response.serverNow)
            show(fresh)
            memory.insert(fresh, userID: userID)
            do {
                try database?.replaceUserReports(response.reports, restaurant: response.restaurant, userId: userID)
            } catch {
                storageWarning = "El restaurante se cargó, pero no se pudo guardar la copia para verlo sin conexión."
            }
        } catch is CancellationError {
        } catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    // pinta una copia, venga de memoria, de la base o del server
    private func show(_ snapshot: ReportedRestaurantSnapshot) {
        restaurant = snapshot.restaurant
        reports = snapshot.reports
        lastSyncDate = snapshot.lastSyncDate
    }
}
