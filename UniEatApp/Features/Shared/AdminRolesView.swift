import SwiftUI

/// la api vuelve a revisar que sea admin en cada cambio de rol y lo deja registrado
struct AdminRolesView: View {
    @EnvironmentObject private var model: AdminRolesViewModel

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Administrar roles").font(.headline)
                Text("Solo otro administrador puede conceder o quitar el rol de administrador. Los restaurantes se habilitan aprobando su solicitud de local.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Actualizar usuarios") { Task { await model.load() } }
                ForEach(model.users) { user in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.displayName).font(.subheadline.weight(.semibold))
                            Text("\(roleName(user.role)) · \(user.id.uuidString.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if user.id != model.profileID {
                            Button(user.role == "admin" ? "Quitar admin" : "Hacer admin") {
                                model.selected = user
                                model.confirming = true
                            }
                            .font(.caption.weight(.bold))
                            .disabled(model.workingID != nil)
                        }
                    }
                    Divider()
                }
                if let message = model.message { Text(message).font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
        .alert("Confirmar cambio de rol", isPresented: $model.confirming) {
            Button("Cancelar", role: .cancel) { model.selected = nil }
            Button("Confirmar") {
                if let selected = model.selected { Task { await model.change(selected) } }
            }
        } message: {
            Text(model.selected.map { "¿\($0.role == "admin" ? "Quitar" : "Conceder") el rol de administrador a \($0.displayName)?" } ?? "")
        }
    }

    private func roleName(_ role: String) -> String {
        switch role {
        case "admin": return "Administrador"
        case "restaurant": return "Restaurante"
        default: return "Estudiante"
        }
    }




}
