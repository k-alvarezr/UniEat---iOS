import Combine
import CoreLocation
import Foundation

/// Lectura puntual del sensor. La coordenada vive solo en memoria y no se envía a la API.
final class LocationContextService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var message: String?

    private let manager = CLLocationManager()
    private var waitingForAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
            message = "Buscando tu zona aproximada…"
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
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "No se obtuvo la ubicación. Elige la zona manualmente."
    }
}
