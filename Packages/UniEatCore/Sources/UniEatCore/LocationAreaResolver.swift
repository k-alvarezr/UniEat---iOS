import Foundation

public struct AreaSuggestion: Equatable, Sendable {
    public let area: String
    public let establishmentName: String
    public let distanceMeters: Int
}

/// Usa los pines publicados por la API, sin límites de barrio inventados ni enviar el GPS.
public enum LocationAreaResolver {
    public static func suggest(latitude: Double, longitude: Double, menus: [DailyMenu],
                               maximumDistanceMeters: Double = 800) -> AreaSuggestion? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let nearest = menus.compactMap { menu -> (DailyMenu, Double)? in
            guard let lat = menu.latitude, let lon = menu.longitude,
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return (menu, distance(latitude, longitude, lat, lon))
        }.min { $0.1 < $1.1 }
        guard let (menu, meters) = nearest, meters <= maximumDistanceMeters else { return nil }
        return AreaSuggestion(area: menu.area, establishmentName: menu.establishmentName,
                              distanceMeters: Int(meters.rounded()))
    }

    private static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let latDelta = (lat2 - lat1) * .pi / 180
        let lonDelta = (lon2 - lon1) * .pi / 180
        let a = pow(sin(latDelta / 2), 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(lonDelta / 2), 2)
        return 2 * radius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
