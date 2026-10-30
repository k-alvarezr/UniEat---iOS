import Combine
import CoreLocation
import MapKit
import SwiftUI
import Foundation

@MainActor
/// estado del formulario para pedir un local que antes estaba en EstablishmentManagementView
/// incluye el pin del mapa, la direccion y la foto publica https
final class EstablishmentViewModel: FeatureViewModel {
    @Published var showingForm = false
    @Published var name = ""
    @Published var area = "Centro"
    @Published var address = ""
    @Published var entranceDescription = ""
    @Published var photoURL = ""
    @Published var paymentMethods: Set<String> = ["Efectivo"]
    @Published var isWorking = false
    @Published var message: String?
    // ubicacion elegida en el mapa, nil si no hay
    @Published var pin: CLLocationCoordinate2D?
    // true si el pin salio de la direccion y no del gps o del mapa
    @Published var pinFromAddress = false
    @Published var pinMessage: String?
    @Published var isGeocoding = false
    @Published var mapPosition: MapCameraPosition = .automatic
    private let service: AccountService
    private let session: SessionStore
    init(service: AccountService, session: SessionStore) {
        self.service = service; self.session = session; super.init(); observe(session)
    }
    var memberships: [RemoteMembership] { session.memberships }
    var isRestaurant: Bool { session.isRestaurant }
    /// al cambiar de cuenta se limpia el formulario
    func reset() {
        showingForm = false; name = ""; area = "Centro"; address = ""; entranceDescription = ""
        photoURL = ""; paymentMethods = ["Efectivo"]; isWorking = false; message = nil
        pin = nil; pinFromAddress = false; pinMessage = nil; isGeocoding = false; mapPosition = .automatic
    }
    let methods = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]
    /// nombre, direccion, un metodo de pago y foto valida o vacia
    var canSubmit: Bool {
        !isWorking && !name.trimmed.isEmpty &&
        !address.trimmed.isEmpty && !paymentMethods.isEmpty &&
        validPhotoURL
    }
    /// la foto es opcional, si va tiene que ser https y sin usuario ni clave en la url
    var validPhotoURL: Bool {
        let value = photoURL.trimmed
        if value.isEmpty { return true }
        guard value.count <= 500, let url = URLComponents(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    /// busca la direccion y pone el pin aproximado
    /// si cambio la sesion o la direccion mientras buscaba no se usa el resultado
    func showAddressOnMap() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation, requested = address
        isGeocoding = true
        defer { if session.matches(userID, generation: generation) { isGeocoding = false } }
        let found = await geocode(requested)
        guard session.matches(userID, generation: generation), address == requested else { return }
        if let found {
            setPin(found, fromAddress: true)
            pinMessage = "Ubicación aproximada según la dirección. Revísala en el mapa."
        } else {
            pinMessage = "No encontramos esa dirección. Usa tu ubicación estando en el local o mueve el pin."
        }
    }
    /// direccion -> coordenadas con el geocoder de apple, en bogota
    func geocode(_ text: String) async -> CLLocationCoordinate2D? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        let placemarks = try? await CLGeocoder().geocodeAddressString("\(trimmed), Bogotá, Colombia")
        return placemarks?.first?.location?.coordinate
    }
    /// pone el pin y centra el mapa ahi
    func setPin(_ coordinate: CLLocationCoordinate2D, fromAddress: Bool) {
        pin = coordinate
        pinFromAddress = fromAddress
        mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                 span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
    }
    /// recarga la cuenta para ver si ya aprobaron el local
    func updateStatus() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.refreshAccount()
            message = session.isRestaurant ? "Tu cuenta ya puede publicar menús." : "Estado actualizado. Las solicitudes pendientes requieren aprobación."
        } catch {
            message = error.localizedDescription
        }
    }
    /// manda la solicitud del local, queda pendiente hasta que un admin la apruebe
    func submit() async {
        guard canSubmit, let userID = session.profile?.id else { return }
        let generation = session.generation
        isWorking = true
        defer { if session.matches(userID, generation: generation) { isWorking = false } }
        // si no hay pin se intenta con la direccion, si tampoco sale se manda sin coordenadas
        var coordinate = pin
        if coordinate == nil { coordinate = await geocode(address) }
        guard session.matches(userID, generation: generation) else { return }
        let photo = photoURL.trimmed
        let request = EstablishmentRequestBody(
            name: name.trimmed, area: area, address: address.trimmed,
            entranceDescription: entranceDescription.trimmed,
            paymentMethods: methods.filter(paymentMethods.contains),
            photoUrl: photo.isEmpty ? nil : photo,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        do {
            try await service.requestEstablishment(request)
            guard session.matches(userID, generation: generation) else { return }
            message = "Solicitud enviada. Podrás publicar cuando un administrador la apruebe."
            name = ""
            address = ""
            entranceDescription = ""
            photoURL = ""
            pin = nil
            pinMessage = nil
            showingForm = false
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            message = error.localizedDescription
        }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
