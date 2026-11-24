import SwiftUI
import UniEatCore

/// detalle de un restaurante: crea su viewmodel desde el contenedor, igual que MenuDetailView
struct ReportHistoryPlaceView: View {
    @EnvironmentObject private var app: AppContainer
    let place: ReportHistoryPlace
    var body: some View { ReportHistoryPlaceScreen(model: app.makeReportHistoryPlace(place)) }
}

private struct ReportHistoryPlaceScreen: View {
    // StateObject guarda el primero y no vuelve a crear el viewmodel en cada redibujado
    @StateObject private var store: ReportHistoryPlaceViewModel
    init(model: @autoclosure @escaping () -> ReportHistoryPlaceViewModel) { _store = StateObject(wrappedValue: model()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: store.place.name, subtitle: store.place.area)
                Text("\(store.place.total) reportes · \(store.place.confirmed) confirmados · \(store.place.pending) en revisión")
                    .font(.subheadline)
                if let fetchedAt = store.fetchedAt {
                    Text("Actualizado: \(SpanishPresentation.dateAndTime(fetchedAt))")
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
        .navigationTitle(store.place.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    private func reportCard(_ report: ReportHistoryEntry) -> some View {
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
