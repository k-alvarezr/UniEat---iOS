import Combine
import Foundation
import UniEatCore

@MainActor
/// las metricas salen del AppStore viejo a su propio viewmodel
/// admin ve el panel global y restaurante solo sus locales, ambos por periodo de 7 o 28 dias
final class PerformanceViewModel: FeatureViewModel {
    // periodo elegido, 7 o 28 dias
    @Published var days = 7
    // panel de admin por periodo
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]
    // metricas del restaurante por periodo
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]
    @Published private(set) var performanceError: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let events: EventService
    private let connectivity: ConnectivityService
    // id de la ultima carga, una respuesta vieja no pisa una nueva
    private var requestID = UUID()
    init(api: APIRequesting, session: SessionStore, events: EventService, connectivity: ConnectivityService) {
        self.api = api; self.session = session; self.events = events; self.connectivity = connectivity
        super.init(); observe(session); observe(connectivity)
    }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var isOffline: Bool { connectivity.isOffline }
    /// al cambiar de cuenta se borra todo para que nadie vea metricas de otro
    func reset() { requestID = UUID(); adminDashboard = [:]; restaurantPerformance = [:]; performanceError = nil; days = 7 }
    /// recarga la cuenta por si cambio el rol, manda la cola de eventos y pide las metricas
    /// si cambio la sesion o arranco otra carga mientras tanto se bota la respuesta
    func loadPerformance(days: Int) async {
        guard let userID = session.profile?.id, !connectivity.isOffline else { return }
        let expected = session.generation, id = UUID()
        requestID = id; performanceError = nil
        do {
            try await session.refreshAccount()
            await events.flush()
            guard session.matches(userID, generation: expected), requestID == id else { return }
            let query = [URLQueryItem(name: "days", value: String(days))]
            if isAdmin {
                let value: AdminDashboardSnapshot = try await api.get("admin/dashboard", query: query)
                guard session.matches(userID, generation: expected), requestID == id else { return }
                adminDashboard[days] = value
            } else if isRestaurant {
                let value: PerformanceSummary = try await api.get("restaurant/performance", query: query)
                guard session.matches(userID, generation: expected), requestID == id else { return }
                restaurantPerformance[days] = value
            }
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: expected), requestID == id else { return }
            performanceError = error.localizedDescription
        }
    }
}
