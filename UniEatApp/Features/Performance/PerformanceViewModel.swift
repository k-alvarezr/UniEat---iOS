import Combine
import Foundation
import UniEatCore

/// las metricas salen del AppStore viejo a su propio viewmodel
/// admin ve el panel global y restaurante solo sus locales, ambos por periodo de 7 o 28 dias
@MainActor
final class PerformanceViewModel: FeatureViewModel {
    // periodo elegido, 7 o 28 dias
    @Published var days = 7
    // panel de admin por periodo
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]
    // metricas del restaurante por periodo
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]
    @Published private(set) var performanceError: String?
    @Published private(set) var isLoading = false
    private let api: APIRequesting
    private let session: SessionStore
    private let events: EventService
    private let connectivity: ConnectivityService
    // id de la ultima carga, una respuesta vieja no pisa una nueva
    private var requestID = UUID()
    private var accountCheckedAt: Date?   // cuando se reviso la cuenta por ultima vez
    init(api: APIRequesting, session: SessionStore, events: EventService, connectivity: ConnectivityService) {
        self.api = api
        self.session = session
        self.events = events
        self.connectivity = connectivity
        super.init()
        observe(session)
        observe(connectivity)
    }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var isOffline: Bool { connectivity.isOffline }
    var isConnected: Bool { connectivity.isConnected }
    /// al cambiar de cuenta se borra todo para que nadie vea metricas de otro
    func reset() {
        accountCheckedAt = nil
        requestID = UUID()
        adminDashboard = [:]
        restaurantPerformance = [:]
        performanceError = nil
        isLoading = false
        days = 7
    }
    /// recarga la cuenta por si cambio el rol, manda la cola de eventos y pide las metricas
    /// si cambio la sesion o arranco otra carga mientras tanto se bota la respuesta
    func loadPerformance(days: Int) async {
        guard let userID = session.profile?.id else { return }
        let expected = session.generation, id = UUID()
        requestID = id
        // Sin internet se conservan las cifras disponibles y no se inicia un spinner ni una peticion.
        guard connectivity.isConnected else {
            isLoading = false
            return
        }
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        performanceError = nil
        do {
            // el rol se revisa con el server maximo cada 2 minutos, no en cada refresco de 10 s
            // igual el server rechaza el panel si el rol ya no alcanza
            if accountCheckedAt.map({ Date.now.timeIntervalSince($0) > 120 }) ?? true {
                try await session.refreshAccount()
                accountCheckedAt = .now
            }
            await events.flush()
            guard session.matches(userID, generation: expected), requestID == id,
                  connectivity.isConnected, !Task.isCancelled else { return }
            let query = [URLQueryItem(name: "days", value: String(days))]
            if isAdmin {
                let value: AdminDashboardSnapshot = try await api.get("admin/dashboard", query: query)
                guard session.matches(userID, generation: expected), requestID == id,
                      connectivity.isConnected, !Task.isCancelled else { return }
                adminDashboard[days] = value
            } else if isRestaurant {
                let value: PerformanceSummary = try await api.get("restaurant/performance", query: query)
                guard session.matches(userID, generation: expected), requestID == id,
                      connectivity.isConnected, !Task.isCancelled else { return }
                restaurantPerformance[days] = value
            }
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: expected), requestID == id else { return }
            performanceError = error.localizedDescription
        }
    }
}
