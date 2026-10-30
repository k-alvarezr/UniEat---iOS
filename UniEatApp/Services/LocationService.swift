import Combine
import CoreLocation
import Foundation

/// lee el gps una sola vez, la coordenada no se guarda ni se manda a la api
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var message: String?

    private let manager = CLLocationManager()
    private var waitingForAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// true si el usuario ya dio permiso de ubicacion al usar la app
    var isAuthorized: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    func request() {
        location = nil
        guard CLLocationManager.locationServicesEnabled() else {
            message = "Activa la ubicación del dispositivo o elige la zona manualmente."
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            waitingForAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            message = "Buscando tu ubicación…"
            manager.requestLocation()
        case .denied, .restricted:
            message = "Sin permiso de ubicación. Elige la zona manualmente o cambia el permiso en Ajustes."
        @unknown default:
            message = "No se pudo consultar la ubicación. Elige la zona manualmente."
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingForAuthorization else { return }
        waitingForAuthorization = false
        request()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0,
              latest.horizontalAccuracy <= 500,
              abs(latest.timestamp.timeIntervalSinceNow) <= 60 else {
            message = "La ubicación es demasiado imprecisa. Elige la zona manualmente."
            return
        }
        location = latest
        message = nil       // ya hay una lectura buena, se quita el "buscando tu ubicacion"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "No se obtuvo la ubicación. Elige la zona manualmente."
    }
}
