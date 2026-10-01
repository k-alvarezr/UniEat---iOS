import SwiftUI

struct EstablishmentManagementView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingForm = false
    @State private var name = ""
    @State private var area = "Centro"
    @State private var address = ""
    @State private var entranceDescription = ""
    @State private var paymentMethods: Set<String> = ["Efectivo"]
    @State private var isWorking = false
    @State private var message: String?

    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]
    private let methods = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]

    private var canSubmit: Bool {
        !isWorking && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !paymentMethods.isEmpty
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mis establecimientos").font(.headline)
                if store.remoteMemberships.isEmpty {
                    Text("Aún no tienes un local registrado. Solicítalo para poder publicar menús.")
                        .font(.subheadline)
                } else {
                    ForEach(store.remoteMemberships) { membership in
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
                        TextField("Cómo encontrar la entrada (opcional)", text: $entranceDescription)
                            .textFieldStyle(.roundedBorder)
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
        do {
            try await store.requestEstablishment(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), area: area,
                address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                entranceDescription: entranceDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                paymentMethods: methods.filter { paymentMethods.contains($0) })
            message = "Solicitud enviada. Podrás publicar cuando un administrador la apruebe."
            name = ""
            address = ""
            entranceDescription = ""
            showingForm = false
        } catch {
            message = error.localizedDescription
        }
    }
}

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
