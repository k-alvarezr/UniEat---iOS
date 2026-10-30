import Combine
import Foundation
import UniEatCore

@MainActor
/// estado de elige por mi, usa el mismo feed y filtros de hoy, no pide nada nuevo
/// conserva el orden del server rank-v1, el primero compatible es la sugerencia
final class RecommendationViewModel: FeatureViewModel {
    // posicion del menu sugerido en la lista
    @Published private(set) var index = 0
    private let feed: FeedViewModel
    init(feed: FeedViewModel) { self.feed = feed; super.init(); observe(feed) }
    var visibleMenus: [DailyMenu] { feed.visibleMenus }
    var filters: FeedFilters { feed.filters }
    var isShowingCachedFeed: Bool { feed.isShowingCachedFeed || feed.isOffline }
    var hasSnapshot: Bool { feed.hasSnapshot }
    var fetchedAt: Date { feed.fetchedAt }
    var now: Date { feed.clock.now }
    var loadError: String? { feed.loadError }
    var isLoading: Bool { feed.isLoading }
    func refresh() async { await feed.refresh(force: true) }
    func next() { index = (index + 1) % max(visibleMenus.count, 1) }
    func reset() { index = 0 }
}
