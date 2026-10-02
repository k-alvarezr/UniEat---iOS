import SwiftUI

/// The API checks the acting admin again for every role change and records an audit row.
struct AdminRolesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var users: [AdminUser] = []
    @State private var selected: AdminUser?
    @State private var confirming = false
    @State private var workingID: UUID?
    @State private var message: String?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Administrar roles").font(.headline)
                Text("Solo otro administrador puede conceder o quitar el rol de administrador. Los restaurantes se habilitan aprobando su solicitud de local.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Actualizar usuarios") { Task { await load() } }
                ForEach(users) { user in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.displayName).font(.subheadline.weight(.semibold))
                            Text("\(roleName(user.role)) · \(user.id.uuidString.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if user.id != store.profile?.id {
                            Button(user.role == "admin" ? "Quitar admin" : "Hacer admin") {
                                selected = user
                                confirming = true
                            }
                            .font(.caption.weight(.bold))
                            .disabled(workingID != nil)
                        }
                    }
                    Divider()
                }
                if let message { Text(message).font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .alert("Confirmar cambio de rol", isPresented: $confirming) {
            Button("Cancelar", role: .cancel) { selected = nil }
            Button("Confirmar") {
                if let selected { Task { await change(selected) } }
            }
        } message: {
            Text(selected.map { "¿\($0.role == "admin" ? "Quitar" : "Conceder") el rol de administrador a \($0.displayName)?" } ?? "")
        }
    }

    private func roleName(_ role: String) -> String {
        switch role {
        case "admin": return "Administrador"
        case "restaurant": return "Restaurante"
        default: return "Estudiante"
        }
    }

    private func load() async {
        guard store.isAdmin else { users = []; return }
        do {
            users = try await store.adminUsers()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func change(_ user: AdminUser) async {
        workingID = user.id
        defer { workingID = nil; selected = nil }
        do {
            try await store.setAdminRole(for: user, enabled: user.role != "admin")
            await load()
            message = "Rol actualizado. El cambio se aplicará al actualizar la cuenta del usuario."
        } catch {
            message = error.localizedDescription
        }
    }
}
