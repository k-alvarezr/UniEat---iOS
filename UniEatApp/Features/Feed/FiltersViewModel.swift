import Combine
import CoreLocation
import Foundation
import UniEatCore

@MainActor
final class FiltersViewModel: FeatureViewModel {
    @Published var draft = FeedFilters()
    @Published var locationMessage: String?
    private let feed: FeedViewModel
    init(feed: FeedViewModel) { self.feed = feed; super.init(); observe(feed) }
    var filters: FeedFilters { feed.filters }
    var usesCachedCatalog: Bool { feed.isOffline || feed.isShowingCachedFeed }
    var hasSnapshot: Bool { feed.hasSnapshot }
    var fetchedAt: Date { feed.fetchedAt }
    func reset() { draft = feed.filters; locationMessage = nil }
    func apply() { feed.updateFilters(draft) }
    func suggest(_ position: CLLocation?) {
        guard let position else { return }
        if let suggestion = LocationAreaResolver.suggest(latitude: position.coordinate.latitude,
            longitude: position.coordinate.longitude, menus: feed.locationMenus.isEmpty ? feed.menus : feed.locationMenus) {
            draft.area = suggestion.area
            locationMessage = "Zona sugerida: \(suggestion.area), cerca de \(suggestion.establishmentName) (~\(suggestion.distanceMeters) m). Puedes cambiarla."
        } else {
            locationMessage = "No encontramos un local publicado cerca. Elige tu zona manualmente."
        }
    }
}
