import SwiftUI
import UniEatCore

/// admin aprueba los locales, al aprobar el usuario pasa a restaurante
struct AdminApprovalsView: View {
    // las solicitudes viven en AdminApprovalsViewModel
    @EnvironmentObject private var model: AdminApprovalsViewModel

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Solicitudes de restaurantes").font(.headline)
                Button("Actualizar solicitudes") { Task { await model.load() } }
                    .disabled(!model.canUseNetwork || model.isLoading)
                if model.isLoading { ProgressView("Consultando solicitudes…") }
                if !model.hasLoaded && !model.isLoading {
                    Text("Aún no hay una lista descargada. Actualiza las solicitudes cuando el servicio esté disponible.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if model.requests.isEmpty && model.hasLoaded {
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
                        .disabled(!model.canUseNetwork || model.workingId != nil)
                    }
                }
                if let message = model.message { Text(message).font(.footnote) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.load() }
    }

}
