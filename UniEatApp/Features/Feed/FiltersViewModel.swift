import Combine
import CoreLocation
import Foundation
import UniEatCore

@MainActor
/// estado de la pantalla de filtros, se edita un borrador y solo al aplicar cambia el feed
final class FiltersViewModel: FeatureViewModel {
    // filtros que la persona esta editando, todavia sin aplicar
    @Published var draft = FeedFilters()
    // texto de la zona sugerida por gps o de que no hay locales cerca
    @Published var locationMessage: String?
    private let feed: FeedViewModel
    init(feed: FeedViewModel) { self.feed = feed; super.init(); observe(feed) }
    var filters: FeedFilters { feed.filters }
    /// al abrir la pantalla el borrador arranca con los filtros aplicados
    func reset() { draft = feed.filters; locationMessage = nil }
    /// aplica el borrador, el feed los guarda y vuelve a pedir
    func apply() { feed.updateFilters(draft) }
    /// sugiere zona por cercania a los locales publicados, la persona puede cambiarla
    /// la ubicacion no se guarda ni se manda al server
    func suggest(_ position: CLLocation?) {
        guard let position else { return }
        if let suggestion = LocationAreaResolver.suggest(latitude: position.coordinate.latitude,
            longitude: position.coordinate.longitude, menus: feed.menus) {
            draft.area = suggestion.area
            locationMessage = "Zona sugerida: \(suggestion.area), cerca de \(suggestion.establishmentName) (~\(suggestion.distanceMeters) m). Puedes cambiarla."
        } else {
            locationMessage = "No encontramos un local publicado cerca. Elige tu zona manualmente."
        }
    }
}
