import CoreLocation
import MapKit
import SwiftUI

/// perfil de estudiante o restaurante, estado de sus locales y pedir uno nuevo con su ubicacion
struct EstablishmentManagementView: View {
    @EnvironmentObject private var model: EstablishmentViewModel
    // pin del local, sale de la direccion o del gps y el dueño lo confirma en el mapa
    @StateObject private var location = LocationContextService()

    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]
    private let methods = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mis establecimientos").font(.headline)
                if model.memberships.isEmpty {
                    Text("Aún no tienes un local registrado. Solicítalo para poder publicar menús.")
                        .font(.subheadline)
                } else {
                    ForEach(model.memberships) { membership in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(membership.establishmentName).font(.subheadline.weight(.bold))
                            Text("\(membership.area) · \(membership.approved ? "Aprobado para publicar" : "Pendiente de aprobación")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(model.isWorking ? "Actualizando…" : "Actualizar estado") {
                    Task { await model.updateStatus() }
                }
                .disabled(model.isWorking)

                DisclosureGroup("Solicitar un establecimiento", isExpanded: $model.showingForm) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Un administrador revisará la solicitud antes de habilitar las publicaciones.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Nombre del local", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                        Picker("Área", selection: $model.area) {
                            ForEach(areas, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Dirección", text: $model.address)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.address) { _, _ in
                                // si cambia la direccion el pin de la direccion ya no sirve, el del gps si se queda
                                if model.pinFromAddress { model.pin = nil; model.pinMessage = nil }
                            }
                        pinPicker
                        TextField("Cómo encontrar la entrada (opcional)", text: $model.entranceDescription)
                            .textFieldStyle(.roundedBorder)
                        TextField("Enlace HTTPS de foto (opcional)", text: $model.photoURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Text("La foto del local aparecerá en sus menús. Usa una imagen pública con permiso para mostrarla.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !model.validPhotoURL {
                            Text("Usa un enlace HTTPS válido, sin usuario ni contraseña.")
                                .font(.footnote).foregroundStyle(Palette.coral)
                        }
                        Text("Medios de pago").font(.subheadline.weight(.semibold))
                        ForEach(methods, id: \.self) { method in
                            Toggle(method, isOn: Binding(
                                get: { model.paymentMethods.contains(method) },
                                set: { selected in
                                    if selected { model.paymentMethods.insert(method) }
                                    else { model.paymentMethods.remove(method) }
                                }
                            ))
                        }
                        Button(model.isWorking ? "Enviando…" : "Enviar solicitud") {
                            Task { await model.submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSubmit)
                    }
                    .padding(.top, 8)
                }
                if let message = model.message {
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
                Button(model.isGeocoding ? "Buscando…" : "Buscar dirección") {
                    Task { await model.showAddressOnMap() }
                }
                .disabled(model.isGeocoding || model.address.trimmed.isEmpty)
                Button {
                    model.pinMessage = nil
                    location.request()
                } label: {
                    Label("Usar mi ubicación", systemImage: "location")
                }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            if let pin = model.pin {
                MapReader { proxy in
                    Map(position: $model.mapPosition) {
                        Marker(model.name.isEmpty ? "Tu local" : model.name, coordinate: pin)
                    }
                    .onTapGesture { point in
                        guard let tapped = proxy.convert(point, from: .local) else { return }
                        model.pin = tapped
                        model.pinFromAddress = false
                        model.pinMessage = "Pin movido manualmente."
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("¿Es aquí tu local? Toca el mapa para mover el pin.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let text = model.pinMessage ?? location.message {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Los estudiantes usan este pin para ver el mapa, abrir indicaciones y sugerir su zona.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onReceive(location.$location) { position in
            guard let position else { return }
            model.setPin(position.coordinate, fromAddress: false)
            model.pinMessage = "Pin tomado de tu ubicación actual (±\(Int(position.horizontalAccuracy)) m). Úsalo estando en el local."
        }
    }

    /// pasa la direccion a coordenadas con el geocodificador de apple, en el celular y sin clave
    /// se le pone la ciudad porque las direcciones tipo Calle 19 #1-21 no la traen

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// admin aprueba los locales, al aprobar el usuario pasa a restaurante
struct AdminApprovalsView: View {
    @EnvironmentObject private var model: AdminApprovalsViewModel

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Solicitudes de restaurantes").font(.headline)
                Button("Actualizar solicitudes") { Task { await model.load() } }
                if model.requests.isEmpty {
                    Text("No hay solicitudes pendientes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(model.requests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.establishmentName).font(.subheadline.weight(.bold))
                        Text("\(request.area) · \(request.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.workingId == request.id ? "Aprobando…" : "Aprobar local") {
                            Task { await model.approve(request) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.workingId != nil)
                    }
                }
                if let message = model.message { Text(message).font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
    }

}
