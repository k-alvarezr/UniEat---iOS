import CoreLocation

public struct AreaSuggestion: Equatable, Sendable {
    public let area: String
    public let establishmentName: String
    public let distanceMeters: Int
}

/// usa los pines que manda la api, sin inventar barrios y sin mandar el gps
public enum LocationAreaResolver {
    public static func suggest(latitude: Double, longitude: Double, menus: [DailyMenu],
                               maximumDistanceMeters: Double = 800) -> AreaSuggestion? {
        guard isValid(latitude, longitude) else { return nil }

        // se recorre cada menu y se guarda el mas cercano que tenga pin
        var nearestMenu: DailyMenu?
        var nearestDistance = Double.infinity
        for menu in menus {
            guard let lat = menu.latitude, let lon = menu.longitude, isValid(lat, lon) else { continue }
            let meters = distance(latitude, longitude, lat, lon)
            if meters < nearestDistance {
                nearestMenu = menu
                nearestDistance = meters
            }
        }

        // si no hay ninguno o esta muy lejos no se sugiere nada
        guard let menu = nearestMenu, nearestDistance <= maximumDistanceMeters else { return nil }
        return AreaSuggestion(area: menu.area, establishmentName: menu.establishmentName,
                              distanceMeters: Int(nearestDistance.rounded()))
    }

    /// latitud entre -90 y 90, longitud entre -180 y 180
    private static func isValid(_ latitude: Double, _ longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    
    /// metros entre dos puntos siguiendo la curvatura de la tierra
    private static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let from = CLLocation(latitude: lat1, longitude: lon1)
        let to = CLLocation(latitude: lat2, longitude: lon2)
        return from.distance(from: to)
    }
}
