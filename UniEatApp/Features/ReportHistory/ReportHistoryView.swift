import SwiftUI
import UniEatCore

/// Mis reportes: un restaurante por fila con cuantos reportes hay y cuantos se confirmaron
struct ReportHistoryView: View {
    @EnvironmentObject private var store: ReportHistoryViewModel
    @EnvironmentObject private var connectivity: ConnectivityService   // el mismo que usa el aviso de conexion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: "Mis reportes")
                Text("Tus reportes agrupados por restaurante y en qué quedó cada uno.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !store.unsentReports.isEmpty { unsentSection }
                if !store.restaurants.isEmpty { summary }
                // chips con scroll de lado, el segmentado cortaba los textos en el iPhone
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ReportHistoryFilter.allCases) { option in filterChip(option) }
                    }
                    .padding(.vertical, 2)
                }
                if let lastSyncDate = store.lastSyncDate {
                    Text("Actualizado: \(SpanishPresentation.dateAndTime(lastSyncDate))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(Palette.coral) }
                if store.isLoading && store.restaurants.isEmpty { ProgressView("Cargando tus reportes…") }
                if store.restaurants.isEmpty {
                    // solo si de verdad no hay nada: con red, sin reportes por enviar y sin un error que impidio cargar
                    // sin red el aviso de conexion ya explica por que no hay lista
                    if !store.isLoading && connectivity.isConnected && store.unsentReports.isEmpty && store.errorMessage == nil {
                        ContentUnavailableView("Aún no tienes reportes", systemImage: "flag",
                                               description: Text("Abre un menú y toca Reportar un cambio para avisar de algo."))
                    }
                } else if store.filteredRestaurants.isEmpty {
                    ContentUnavailableView("Nada con este filtro", systemImage: "flag",
                                           description: Text("Prueba con otro filtro."))
                } else {
                    ForEach(store.filteredRestaurants) { restaurant in
                        NavigationLink(destination: ReportedRestaurantView(restaurant: restaurant)) { row(restaurant) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .connectionStatus(.reportHistory)
        .navigationTitle("Mis reportes")
        .task { await store.loadRestaurants() }
        .refreshable { await store.loadRestaurants() }
        // al volver la red se actualiza sola, igual que el detalle del menu
        .onChange(of: connectivity.isConnected) { _, connected in
            if connected { Task { await store.loadRestaurants() } }
        }
        // cuando la cola se manda (o entra un reporte nuevo) se relee la seccion Por enviar
        .onChange(of: store.unsentCount) { _, _ in store.loadUnsentReports() }
    }

    /// reportes hechos sin red: estan en el celular y se mandan solos al volver la conexion
    private var unsentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Por enviar (\(store.unsentReports.count))").font(.headline)
            ForEach(store.unsentReports, id: \.id) { report in
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 5) {
                        let kind = ReportKind(rawValue: report.kind)
                        Label(kind?.historyTitle ?? "Reporte", systemImage: kind?.historyIcon ?? "flag").font(.headline)
                        Text("\(report.snapshot?.title ?? "Menú") · \(report.snapshot?.establishmentName ?? "Restaurante")")
                            .font(.subheadline)
                        if !report.note.isEmpty { Text("“\(report.note)”").font(.caption).italic() }
                        HStack {
                            Sticker(text: "Pendiente de enviar", color: Palette.yellow)
                            Spacer()
                            Text(SpanishPresentation.dateAndTime(report.createdAt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Se envían solos cuando vuelva la conexión.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        SurfaceCard {
            HStack {
                Label("\(store.totalReports) reportes", systemImage: "flag.fill")
                Spacer()
                Label("\(store.totalConfirmed) confirmados", systemImage: "checkmark.seal.fill")
            }
            .font(.rounded(15))
        }
    }

    private func row(_ restaurant: ReportedRestaurant) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(restaurant.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                Text("\(restaurant.area) · último reporte \(SpanishPresentation.dayAndMonth(restaurant.lastReportAt))")
                    .font(.caption).foregroundStyle(.secondary)
                // las mismas etiquetas (Sticker) que usa el resto de la app
                HStack(spacing: 6) {
                    Sticker(text: "\(restaurant.total) en total", color: Palette.paper)
                    if restaurant.pending > 0 { Sticker(text: "\(restaurant.pending) en revisión", color: Palette.yellow) }
                    if restaurant.confirmed > 0 { Sticker(text: "\(restaurant.confirmed) confirmados", color: Palette.green) }
                    if restaurant.dismissed > 0 { Sticker(text: "\(restaurant.dismissed) descartados", color: Palette.coral) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// opcion del filtro con cuantos restaurantes entran, la elegida va en amarillo
    private func filterChip(_ option: ReportHistoryFilter) -> some View {
        let selected = store.filter == option
        return Button { store.filter = option } label: {
            Text("\(option.title) (\(store.restaurantCount(matching: option)))")
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Palette.yellow : Palette.paper, in: Capsule())
                .overlay(Capsule().stroke(Palette.ink, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
