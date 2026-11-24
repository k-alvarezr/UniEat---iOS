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
                if !store.places.isEmpty { summary }
                Picker("Filtro", selection: $store.filter) {
                    ForEach(ReportHistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let fetchedAt = store.fetchedAt {
                    Text("Actualizado: \(SpanishPresentation.dateAndTime(fetchedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(Palette.coral) }
                if store.isLoading && store.places.isEmpty { ProgressView("Cargando tus reportes…") }
                if store.visiblePlaces.isEmpty && !store.isLoading {
                    ContentUnavailableView(store.places.isEmpty ? "Aún no tienes reportes" : "Nada con este filtro",
                                           systemImage: "flag",
                                           description: Text(store.places.isEmpty
                                               ? "Abre un menú y toca Reportar para avisar de un cambio."
                                               : "Prueba con otro filtro."))
                } else {
                    ForEach(store.visiblePlaces) { place in
                        NavigationLink(destination: ReportHistoryPlaceView(place: place)) { row(place) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .connectionStatus(.reportHistory)
        .navigationTitle("Mis reportes")
        .task { await store.load() }
        .refreshable { await store.load() }
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

    private func row(_ place: ReportHistoryPlace) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(place.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                Text("\(place.area) · último reporte \(SpanishPresentation.dayAndMonth(place.lastReportAt))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    chip("\(place.total) en total", color: Palette.paper)
                    if place.pending > 0 { chip("\(place.pending) en revisión", color: Palette.yellow) }
                    if place.confirmed > 0 { chip("\(place.confirmed) confirmados", color: Palette.green) }
                    if place.dismissed > 0 { chip("\(place.dismissed) descartados", color: Palette.coral) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(Palette.ink, lineWidth: 1))
    }
}
