import Combine
import Foundation
import UniEatCore

/// lista de Mis reportes: los restaurantes donde el usuario reporto, con el conteo por estado
/// por ahora solo red, la copia local, la precarga y la LRU llegan en sus propias issues
@MainActor
final class ReportHistoryViewModel: FeatureViewModel {
    @Published private(set) var places: [ReportHistoryPlace] = []
    @Published private(set) var fetchedAt: Date?          // hora del server de la ultima respuesta
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var filter: ReportHistoryFilter = .all
    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private var requestID = UUID()   // una respuesta vieja no pisa una nueva
    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
        super.init()
        observe(connectivity)
    }
    var isOffline: Bool { connectivity.isOffline }
    /// restaurantes que pasan el filtro elegido
    var visiblePlaces: [ReportHistoryPlace] { places.filter(filter.includes) }
    /// cuantos restaurantes entran en cada opcion, para mostrarlo en el chip
    func count(for option: ReportHistoryFilter) -> Int { places.filter(option.includes).count }
    /// resumen de arriba, suma de todos los restaurantes sin importar el filtro
    var totalReports: Int { places.reduce(0) { $0 + $1.total } }
    var totalConfirmed: Int { places.reduce(0) { $0 + $1.confirmed } }

    /// al cambiar de cuenta se bota todo para que nadie vea reportes de otro
    func reset() {
        requestID = UUID()
        places = []
        fetchedAt = nil
        isLoading = false
        errorMessage = nil
        filter = .all
    }

    /// pide la lista al server, si cambio la sesion o arranco otra carga se bota la respuesta
    func load() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID()
        requestID = id
        guard connectivity.isConnected else {
            errorMessage = APIFailure.offline.message
            return
        }
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }
        do {
            let response: ReportHistoryPlacesResponse = try await api.get("me/reports/places", query: [])
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            places = response.places
            fetchedAt = response.serverNow
        } catch is CancellationError {
        } catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            errorMessage = error.localizedDescription
        }
    }
}
