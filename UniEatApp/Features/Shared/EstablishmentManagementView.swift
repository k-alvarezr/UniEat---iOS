import CoreLocation
import MapKit
import SwiftUI

/// perfil de estudiante o restaurante, estado de sus locales y pedir uno nuevo con su ubicacion
struct EstablishmentManagementView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingForm = false
    @State private var name = ""
    @State private var area = "Centro"
    @State private var address = ""
    @State private var entranceDescription = ""
    @State private var photoURL = ""
    @State private var paymentMethods: Set<String> = ["Efectivo"]
    @State private var isWorking = false
    @State private var message: String?
    // pin del local, sale de la direccion o del gps y el dueño lo confirma en el mapa
    @StateObject private var location = LocationContextService()
    @State private var pin: CLLocationCoordinate2D?
    @State private var pinFromAddress = false
    @State private var pinMessage: String?
    @State private var isGeocoding = false
    @State private var mapPosition: MapCameraPosition = .automatic

    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]
    private let methods = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]

    private var canSubmit: Bool {
        !isWorking && !name.trimmed.isEmpty &&
        !address.trimmed.isEmpty && !paymentMethods.isEmpty &&
        validPhotoURL
    }

    private var validPhotoURL: Bool {
        let value = photoURL.trimmed
        if value.isEmpty { return true }
        guard value.count <= 500, let url = URLComponents(string: value) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mis establecimientos").font(.headline)
                if store.memberships.isEmpty {
                    Text("Aún no tienes un local registrado. Solicítalo para poder publicar menús.")
                        .font(.subheadline)
                } else {
                    ForEach(store.memberships) { membership in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(membership.establishmentName).font(.subheadline.weight(.bold))
                            Text("\(membership.area) · \(membership.approved ? "Aprobado para publicar" : "Pendiente de aprobación")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(isWorking ? "Actualizando…" : "Actualizar estado") {
                    Task { await updateStatus() }
                }
                .disabled(isWorking)

                DisclosureGroup("Solicitar un establecimiento", isExpanded: $showingForm) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Un administrador revisará la solicitud antes de habilitar las publicaciones.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Nombre del local", text: $name)
                            .textFieldStyle(.roundedBorder)
                        Picker("Área", selection: $area) {
                            ForEach(areas, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Dirección", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: address) { _, _ in
                                // si cambia la direccion el pin de la direccion ya no sirve, el del gps si se queda
                                if pinFromAddress { pin = nil; pinMessage = nil }
                            }
                        pinPicker
                        TextField("Cómo encontrar la entrada (opcional)", text: $entranceDescription)
                            .textFieldStyle(.roundedBorder)
                        TextField("Enlace HTTPS de foto (opcional)", text: $photoURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Text("La foto del local aparecerá en sus menús. Usa una imagen pública con permiso para mostrarla.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !validPhotoURL {
                            Text("Usa un enlace HTTPS válido, sin usuario ni contraseña.")
                                .font(.footnote).foregroundStyle(Palette.coral)
                        }
                        Text("Medios de pago").font(.subheadline.weight(.semibold))
                        ForEach(methods, id: \.self) { method in
                            Toggle(method, isOn: Binding(
                                get: { paymentMethods.contains(method) },
                                set: { selected in
                                    if selected { paymentMethods.insert(method) }
                                    else { paymentMethods.remove(method) }
                                }
                            ))
                        }
                        Button(isWorking ? "Enviando…" : "Enviar solicitud") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit)
                    }
                    .padding(.top, 8)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(Palette.ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ubicacion del local, buscar la direccion o usar el gps y mover el pin en el mapa si hace falta
    @ViewBuilder private var pinPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ubicación del local").font(.subheadline.weight(.semibold))
            HStack {
                Button(isGeocoding ? "Buscando…" : "Buscar dirección") {
                    Task { await showAddressOnMap() }
                }
                .disabled(isGeocoding || address.trimmed.isEmpty)
                Button {
                    pinMessage = nil
                    location.request()
                } label: {
                    Label("Usar mi ubicación", systemImage: "location")
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            if let pin {
                MapReader { proxy in
                    Map(position: $mapPosition) {
                        Marker(name.isEmpty ? "Tu local" : name, coordinate: pin)
                    }
                    .onTapGesture { point in
                        guard let tapped = proxy.convert(point, from: .local) else { return }
                        self.pin = tapped
                        pinFromAddress = false
                        pinMessage = "Pin movido manualmente."
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("¿Es aquí tu local? Toca el mapa para mover el pin.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let text = pinMessage ?? location.message {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Los estudiantes usan este pin para ver el mapa, abrir indicaciones y sugerir su zona.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onReceive(location.$location) { position in
            guard let position else { return }
            setPin(position.coordinate, fromAddress: false)
            pinMessage = "Pin tomado de tu ubicación actual (±\(Int(position.horizontalAccuracy)) m). Úsalo estando en el local."
        }
    }

    private func showAddressOnMap() async {
        isGeocoding = true
        defer { isGeocoding = false }
        if let found = await geocode(address) {
            setPin(found, fromAddress: true)
            pinMessage = "Ubicación aproximada según la dirección. Revísala en el mapa."
        } else {
            pinMessage = "No encontramos esa dirección. Usa tu ubicación estando en el local o mueve el pin."
        }
    }

    /// pasa la direccion a coordenadas con el geocodificador de apple, en el celular y sin clave
    /// se le pone la ciudad porque las direcciones tipo Calle 19 #1-21 no la traen
    private func geocode(_ text: String) async -> CLLocationCoordinate2D? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return nil }
        let placemarks = try? await CLGeocoder().geocodeAddressString("\(trimmed), Bogotá, Colombia")
        return placemarks?.first?.location?.coordinate
    }

    private func setPin(_ coordinate: CLLocationCoordinate2D, fromAddress: Bool) {
        pin = coordinate
        pinFromAddress = fromAddress
        mapPosition = .region(MKCoordinateRegion(center: coordinate,
                                                 span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
    }

    private func updateStatus() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.refreshAccount()
            message = store.isRestaurant ? "Tu cuenta ya puede publicar menús." : "Estado actualizado. Las solicitudes pendientes requieren aprobación."
        } catch {
            message = error.localizedDescription
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isWorking = true
        defer { isWorking = false }
        // si no hay pin se intenta con la direccion, si tampoco sale se manda sin coordenadas
        var coordinate = pin
        if coordinate == nil { coordinate = await geocode(address) }
        let photo = photoURL.trimmed
        let request = EstablishmentRequestBody(
            name: name.trimmed, area: area, address: address.trimmed,
            entranceDescription: entranceDescription.trimmed,
            paymentMethods: methods.filter(paymentMethods.contains),
            photoUrl: photo.isEmpty ? nil : photo,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        do {
            try await store.requestEstablishment(request)
            message = "Solicitud enviada. Podrás publicar cuando un administrador la apruebe."
            name = ""
            address = ""
            entranceDescription = ""
            photoURL = ""
            pin = nil
            pinMessage = nil
            showingForm = false
        } catch {
            message = error.localizedDescription
        }
    }
}

/// admin aprueba los locales, al aprobar el usuario pasa a restaurante
struct AdminApprovalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var requests: [PendingMembership] = []
    @State private var workingId: String?
    @State private var message: String?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Solicitudes de restaurantes").font(.headline)
                Button("Actualizar solicitudes") { Task { await load() } }
                if requests.isEmpty {
                    Text("No hay solicitudes pendientes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(requests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.establishmentName).font(.subheadline.weight(.bold))
                        Text("\(request.area) · \(request.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(workingId == request.id ? "Aprobando…" : "Aprobar local") {
                            Task { await approve(request) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workingId != nil)
                    }
                }
                if let message { Text(message).font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            requests = try await store.pendingMembershipRequests()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func approve(_ request: PendingMembership) async {
        workingId = request.id
        defer { workingId = nil }
        do {
            try await store.approveMembership(request)
            requests.removeAll { $0.id == request.id }
            if let updated = try? await store.pendingMembershipRequests() { requests = updated }
            message = "\(request.establishmentName) aprobado. El dueño debe actualizar su estado en la app."
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
