import Combine
import Foundation
import UniEatCore

/// detalle de un restaurante en Mis reportes, uno por cada vez que se abre (como el detalle del menu)
@MainActor
final class ReportHistoryPlaceViewModel: FeatureViewModel {
    @Published private(set) var place: ReportHistoryPlace
    @Published private(set) var reports: [ReportHistoryEntry] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private var requestID = UUID()
    /// arranca con el resumen de la lista para pintar el encabezado sin esperar la red
    init(place: ReportHistoryPlace, api: APIRequesting, session: SessionStore, connectivity: ConnectivityService) {
        self.place = place
        self.api = api
        self.session = session
        self.connectivity = connectivity
        super.init()
        observe(connectivity)
    }
    var isOffline: Bool { connectivity.isOffline }

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
            let response: ReportHistoryPlaceResponse = try await api.get("me/reports/places/\(place.establishmentId.uuidString)", query: [])
            guard session.matches(userID, generation: generation), requestID == id, !Task.isCancelled else { return }
            place = response.place
            reports = response.reports
            fetchedAt = response.serverNow
        } catch is CancellationError {
        } catch {
            guard session.matches(userID, generation: generation), requestID == id else { return }
            errorMessage = error.localizedDescription
        }
    }
}
