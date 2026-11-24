import Combine
import Foundation
import UniEatCore

/// detalle de un restaurante en Mis reportes, uno por cada vez que se abre (como el detalle del menu)
/// primero la copia de swiftdata y despues el server, lo que llega se guarda para verlo sin red
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
    private let preferences = ReportHistoryPreferences()
    private var requestID = UUID()
    /// arranca con el resumen de la lista para pintar el encabezado sin esperar disco ni red
    init(restaurant: ReportedRestaurant, api: APIRequesting, session: SessionStore, connectivity: ConnectivityService,
         database: LocalDatabase?) {
        self.restaurant = restaurant
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.database = database
        super.init()
        observe(connectivity)
    }
    var isOffline: Bool { connectivity.isOffline }

    func loadReports() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID(), establishmentID = restaurant.establishmentId
        requestID = id
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }

        // 1. lo guardado, si ya hay reportes en pantalla no se vuelve a leer
        if reports.isEmpty, let database {
            do {
                reports = try database.loadUserReports(userId: userID, establishmentId: establishmentID)
                // la copia es de la ultima sincronizacion de Mis reportes
                if !reports.isEmpty { lastSyncDate = preferences.lastSyncDate(userID: userID) }
            } catch {
                storageWarning = "No se pudo leer la copia guardada de este restaurante."
            }
        }

        // 2. el server, sin red se queda lo guardado
        guard connectivity.isConnected else {
            if reports.isEmpty { errorMessage = APIFailure.offline.message }
            return
        }
        do {
            let response: ReportedRestaurantDetailResponse = try await api.get("me/reports/places/\(establishmentID.uuidString)", query: [])
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            restaurant = response.restaurant
            reports = response.reports
            lastSyncDate = response.serverNow
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
}
