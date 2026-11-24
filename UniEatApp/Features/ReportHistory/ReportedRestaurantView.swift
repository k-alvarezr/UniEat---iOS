import SwiftUI
import UniEatCore

/// detalle de un restaurante: crea su viewmodel desde el contenedor, igual que MenuDetailView
struct ReportedRestaurantView: View {
    @EnvironmentObject private var app: AppContainer
    let restaurant: ReportedRestaurant
    var body: some View { ReportedRestaurantScreen(model: app.makeReportedRestaurantViewModel(restaurant)) }
}

private struct ReportedRestaurantScreen: View {
    // StateObject guarda el primero y no vuelve a crear el viewmodel en cada redibujado
    @StateObject private var store: ReportedRestaurantViewModel
    init(model: @autoclosure @escaping () -> ReportedRestaurantViewModel) { _store = StateObject(wrappedValue: model()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: store.restaurant.name, subtitle: store.restaurant.area)
                Text("\(store.restaurant.total) reportes · \(store.restaurant.confirmed) confirmados · \(store.restaurant.pending) en revisión")
                    .font(.subheadline)
                if let lastSyncDate = store.lastSyncDate {
                    Text("Actualizado: \(SpanishPresentation.dateAndTime(lastSyncDate))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(Palette.coral) }
                if store.isLoading && store.reports.isEmpty { ProgressView("Cargando reportes…") }
                ForEach(store.reports) { report in reportCard(report) }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .connectionStatus(.reportHistory)
        .navigationTitle(store.restaurant.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadReports() }
        .refreshable { await store.loadReports() }
        // al volver la red se actualiza solo, igual que el detalle del menu
        .onChange(of: store.isConnected) { _, connected in
            if connected { Task { await store.loadReports() } }
        }
    }

    private func reportCard(_ report: UserReport) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(report.kindTitle, systemImage: report.kindIcon).font(.headline)
                Text("\(report.menuTitle) · versión \(report.version)").font(.subheadline)
                if let minutes = report.observedWaitMinutes { Text("Fila: \(minutes) min").font(.caption) }
                if !report.note.isEmpty { Text("“\(report.note)”").font(.caption).italic() }
                HStack {
                    Text(report.statusTitle)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(report.statusColor, in: Capsule())
                        .overlay(Capsule().stroke(Palette.ink, lineWidth: 1))
                    Spacer()
                    Text(SpanishPresentation.dateAndTime(report.observedAt))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let resolvedAt = report.resolvedAt {
                    Text("Resuelto: \(SpanishPresentation.dateAndTime(resolvedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
