import Combine
import Foundation

@MainActor
final class PublicationTimingViewModel: FeatureViewModel {
    @Published private(set) var snapshot: PublicationTimingSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isShowingCopy = false
    @Published private(set) var errorMessage: String?

    private let api: APIRequesting
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private let content: LocalContentService?
    private var requestID = UUID()
    private var accessDenied = false

    init(api: APIRequesting, session: SessionStore, connectivity: ConnectivityService, content: LocalContentService?) {
        self.api = api
        self.session = session
        self.connectivity = connectivity
        self.content = content
        super.init()
        observe(session)
        observe(connectivity)
    }

    var isRestaurant: Bool { session.isRestaurant }
    var isConnected: Bool { connectivity.isConnected }
    var groups: [PublicationTimingGroup] {
        guard let snapshot else { return [] }
        if !isShowingCopy { return snapshot.groups }
        let approved = Set(session.approvedEstablishments.map(\.id))
        return snapshot.groups.filter { approved.contains($0.id) }
    }

    func reset() {
        requestID = UUID()
        accessDenied = false
        snapshot = nil
        isLoading = false
        isShowingCopy = false
        errorMessage = nil
    }

    func load() async {
        guard isRestaurant, let userID = session.profile?.id else { return }
        let generation = session.generation, id = UUID()
        requestID = id
        isLoading = true
        errorMessage = nil
        defer { if requestID == id { isLoading = false } }

        // La consulta de red no espera a que SwiftData haya recuperado la copia.
        async let remote = fetchWhenConnected(isConnected)
        if snapshot == nil, !accessDenied,
           let stored = try? await content?.publicationTiming(userID: userID), isCurrent(userID, generation, id) {
            snapshot = stored
            isShowingCopy = true
        }

        do {
            guard let fresh = try await remote else {
                if isCurrent(userID, generation, id) { isShowingCopy = snapshot != nil }
                return
            }
            guard isCurrent(userID, generation, id) else { return }
            accessDenied = false
            snapshot = fresh
            isShowingCopy = false
            if let content {
                try await content.savePublicationTiming(fresh, userID: userID, generation: generation)
            }
        } catch is CancellationError {
        } catch let failure as APIFailure where failure.code == "FORBIDDEN" {
            guard isCurrent(userID, generation, id) else { return }
            accessDenied = true
            snapshot = nil
            isShowingCopy = false
            errorMessage = failure.localizedDescription
            try? await content?.clearPublicationTiming(userID: userID, generation: generation)
        } catch {
            guard isCurrent(userID, generation, id) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetchWhenConnected(_ connected: Bool) async throws -> PublicationTimingSnapshot? {
        guard connected else { return nil }
        let snapshot: PublicationTimingSnapshot = try await api.get("restaurant/publication-timing")
        return snapshot
    }

    private func isCurrent(_ userID: UUID, _ generation: UUID, _ id: UUID) -> Bool {
        session.matches(userID, generation: generation) && requestID == id && !Task.isCancelled
    }
}
