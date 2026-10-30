import Combine
import Foundation
import UniEatCore

@MainActor
final class PerformanceViewModel: FeatureViewModel {
    @Published var days = 7
    @Published private(set) var adminDashboard: [Int: AdminDashboardSnapshot] = [:]
    @Published private(set) var restaurantPerformance: [Int: PerformanceSummary] = [:]
    @Published private(set) var performanceError: String?
    private let api: APIRequesting
    private let session: SessionStore
    private let events: EventService
    private let connectivity: ConnectivityService
    private var requestID = UUID()
    init(api: APIRequesting, session: SessionStore, events: EventService, connectivity: ConnectivityService) {
        self.api = api; self.session = session; self.events = events; self.connectivity = connectivity
        super.init(); observe(session); observe(connectivity)
    }
    var isAdmin: Bool { session.isAdmin }
    var isRestaurant: Bool { session.isRestaurant }
    var isOffline: Bool { connectivity.isOffline }
    func reset() { requestID = UUID(); adminDashboard = [:]; restaurantPerformance = [:]; performanceError = nil; days = 7 }
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
