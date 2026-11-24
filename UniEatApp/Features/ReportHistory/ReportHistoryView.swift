import SwiftUI
import UniEatCore

/// Mis reportes: un restaurante por fila con cuantos reportes hay y cuantos se confirmaron
struct ReportHistoryView: View {
    @EnvironmentObject private var store: ReportHistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: "Mis reportes")
                Text("Tus reportes agrupados por restaurante y en qué quedó cada uno.")
                    .font(.subheadline).foregroundStyle(.secondary)
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
                if store.filteredRestaurants.isEmpty && !store.isLoading {
                    ContentUnavailableView(store.restaurants.isEmpty ? "Aún no tienes reportes" : "Nada con este filtro",
                                           systemImage: "flag",
                                           description: Text(store.restaurants.isEmpty
                                               ? "Abre un menú y toca Reportar para avisar de un cambio."
                                               : "Prueba con otro filtro."))
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
                HStack(spacing: 6) {
                    chip("\(restaurant.total) en total", color: Palette.paper)
                    if restaurant.pending > 0 { chip("\(restaurant.pending) en revisión", color: Palette.yellow) }
                    if restaurant.confirmed > 0 { chip("\(restaurant.confirmed) confirmados", color: Palette.green) }
                    if restaurant.dismissed > 0 { chip("\(restaurant.dismissed) descartados", color: Palette.coral) }
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

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(Palette.ink, lineWidth: 1))
    }
}
