import SwiftUI
import UniEatCore

/// pestaña rendimiento solo admin, cada pregunta en el mismo formato de tarjeta
struct PerformanceView: View {
    // las metricas viven en PerformanceViewModel, antes en el AppStore viejo
    @EnvironmentObject private var store: PerformanceViewModel

    var body: some View {
        Group {
            if store.isAdmin {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "UniEat · Rendimiento", showsProfileButton: true)
                        Text("Resumen de iOS para el período elegido. El detalle completo está en el tablero web.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        PeriodPicker(days: $store.days)
                        if let error = store.performanceError {
                            PerformanceErrorCard(message: error) { Task { await store.loadPerformance(days: store.days) } }
                        }
                        if let snapshot = store.adminDashboard[store.days] {
                            Text("Actualizado: \(SpanishPresentation.dateAndTime(snapshot.generatedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                            BQ03Section(metrics: snapshot.bq03)
                            BQ04Section(metrics: snapshot.bq04)
                            if let metrics = snapshot.bq08 { BQ08Section(metrics: metrics) }
                            // la actividad general queda solo para restaurantes y en el tablero web, aca solo preguntas
                        } else if store.isLoading && !store.isOffline {
                            ProgressView("Cargando métricas del servidor…")
                        } else if store.isOffline {
                            OfflinePerformanceEmptyView()
                        } else if store.performanceError == nil {
                            Button("Consultar métricas") { Task { await store.loadPerformance(days: store.days) } }
                        }
                    }
                    .padding(16)
                }
                .background(Palette.cream)
                .refreshingPerformance(days: store.days, store: store)
            } else {
                ContentUnavailableView("Solo administradores", systemImage: "lock.fill",
                                       description: Text("Inicia sesión con una cuenta administradora para ver el tablero global."))
            }
        }
        .connectionStatus(.performance)
    }
}

/// mis metricas para restaurantes, solo la actividad de sus menus
struct RestaurantPerformanceView: View {
    // las metricas viven en PerformanceViewModel, antes en el AppStore viejo
    @EnvironmentObject private var store: PerformanceViewModel

    var body: some View {
        Group {
            if store.isRestaurant {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "Actividad de mis menús", showsProfileButton: true)
                        Text("Solo publicaciones de tus establecimientos aprobados. Las cifras son actividad iOS, no ventas ni visitas verificadas.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        PeriodPicker(days: $store.days)
                        if let error = store.performanceError {
                            PerformanceErrorCard(message: error) { Task { await store.loadPerformance(days: store.days) } }
                        }
                        if let summary = store.restaurantPerformance[store.days] {
                            if store.isOffline {
                                Text("Último panel recibido para este período; no se está actualizando.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            EngagementSection(summary: summary)
                        } else if store.isLoading && !store.isOffline {
                            ProgressView("Cargando métricas del servidor…")
                        } else if store.isOffline {
                            OfflinePerformanceEmptyView()
                        } else if store.performanceError == nil {
                            Button("Consultar métricas") { Task { await store.loadPerformance(days: store.days) } }
                        }
                    }
                    .padding(16)
                }
                .background(Palette.cream)
                .refreshingPerformance(days: store.days, store: store)
            } else {
                ContentUnavailableView("Solo restaurantes", systemImage: "lock.fill")
            }
        }
        .connectionStatus(.performance)
    }
}

private extension View {
    /// carga las metricas y las vuelve a pedir cada 10 segundos mientras la pantalla este abierta
    /// si se cambia el periodo arranca de nuevo
    func refreshingPerformance(days: Int, store: PerformanceViewModel) -> some View {
        task(id: PerformanceRefreshKey(days: days, connected: store.isConnected)) {
            guard store.isConnected else { return }
            while !Task.isCancelled {
                await store.loadPerformance(days: days)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct PerformanceRefreshKey: Hashable {
    let days: Int
    let connected: Bool
}

private struct OfflinePerformanceEmptyView: View {
    var body: some View {
        ContentUnavailableView("No hay una copia de este período", systemImage: "wifi.slash",
            description: Text("Puedes cambiar de período o navegar por la app. El panel se consultará al recuperar conexión."))
    }
}

private struct PeriodPicker: View {
    @Binding var days: Int
    var body: some View {
        Picker("Período", selection: $days) {
            Text("Últimos 7 días").tag(7)
            Text("28 días").tag(28)
        }
        .pickerStyle(.segmented)
    }
}

private struct PerformanceErrorCard: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("No se pudieron actualizar las métricas", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.caption)
                Button("Reintentar", action: retry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - formato comun

/// todas las preguntas del panel se ven igual: titulo con la pregunta, una frase con la respuesta,
/// una sola grafica y una nota corta, el detalle completo esta en el tablero html
private struct QuestionCard<Chart: View>: View {
    let title: String
    let answer: String
    var note: String? = nil
    @ViewBuilder let chart: Chart
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(answer).font(.subheadline)
                chart
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// una parte de una barra: cuanto vale, como se llama y de que color va
private struct BarPart: Identifiable {
    let label: String
    let value: Int
    let color: Color
    var id: String { label }
}

/// barra apilada con su leyenda abajo, las partes suman el total
private struct StackedBar: View {
    let parts: [BarPart]
    var body: some View {
        let total = CGFloat(max(parts.reduce(0) { $0 + $1.value }, 1))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(parts) { part in
                        part.color.frame(width: proxy.size.width * CGFloat(part.value) / total)
                    }
                }
            }
            .frame(height: 14)
            .background(Palette.cream)
            .clipShape(Capsule())
            Legend(parts: parts)
        }
        .accessibilityElement(children: .combine)
    }
}

/// barras horizontales comparadas contra el valor mas grande, para embudos y comparaciones
private struct BarList: View {
    let parts: [BarPart]
    var body: some View {
        let top = CGFloat(max(parts.map(\.value).max() ?? 1, 1))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parts) { part in
                HStack(spacing: 8) {
                    Text(part.label).font(.caption).frame(width: 96, alignment: .leading)
                    GeometryReader { proxy in
                        part.color.frame(width: max(proxy.size.width * CGFloat(part.value) / top, 2))
                            .clipShape(Capsule())
                    }
                    .frame(height: 10)
                    Text("\(part.value)").font(.caption.monospacedDigit()).frame(minWidth: 32, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// puntos de color con su nombre y cifra, debajo de una barra apilada
private struct Legend: View {
    let parts: [BarPart]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(parts) { part in
                HStack(spacing: 4) {
                    Circle().fill(part.color).frame(width: 8, height: 8)
                    Text("\(part.label) \(part.value)").font(.caption)
                }
            }
        }
    }
}

/// de 0 a 1 a "12 %"
private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }

// MARK: - preguntas

/// BQ-03: si las busquedas del feed encuentran menus
private struct BQ03Section: View {
    let metrics: BQ03Metrics
    // exitosas con al menos un menu
    private var withResults: Int { max(metrics.successfulRequests - metrics.zeroResultRequests, 0) }
    var body: some View {
        QuestionCard(title: "BQ-03 · ¿Las búsquedas encuentran menús?",
                     answer: "\(metrics.feedRequests) búsquedas, \(metrics.contextualRequests) con filtros. En promedio \(String(format: "%.1f", metrics.averageResults)) menús por búsqueda.",
                     note: "La copia sin conexión no cuenta como búsqueda.") {
            if metrics.feedRequests > 0 {
                StackedBar(parts: [
                    BarPart(label: "Con menús", value: withResults, color: Palette.green),
                    BarPart(label: "Sin menús", value: metrics.zeroResultRequests, color: Palette.yellow),
                    BarPart(label: "Fallidas", value: metrics.failedRequests, color: Palette.coral),
                ])
            }
        }
    }
}

/// BQ-04: en que estado estan los menus que se abren
private struct BQ04Section: View {
    let metrics: BQ04Metrics
    // vencidos + cerrados, si el back aun no lo manda se suma aca
    private var unavailable: Int { metrics.unavailableShown ?? metrics.expiredShown + metrics.closedShown }
    var body: some View {
        QuestionCard(title: "BQ-04 · ¿En qué estado están los menús que se abren?", answer: answer,
                     note: metrics.rates == nil && metrics.detailRequests > 0 ? "Porcentajes desde 20 consultas." : nil) {
            if metrics.detailRequests > 0 {
                StackedBar(parts: [
                    BarPart(label: "Vigente", value: metrics.activeShown, color: Palette.green),
                    BarPart(label: "Por vencer", value: metrics.expiringShown, color: Palette.yellow),
                    BarPart(label: "No disponible", value: unavailable, color: Palette.coral),
                ])
            }
        }
    }
    // la respuesta en una frase, con porcentajes solo si el server los mando
    private var answer: String {
        let menus = metrics.distinctMenus.map { " de \($0) menús" } ?? ""
        guard let rates = metrics.rates else { return "\(metrics.detailRequests) consultas\(menus)." }
        return "\(metrics.detailRequests) consultas\(menus): \(percent(rates.active)) vigente, \(percent(rates.expiring)) por vencer, \(percent(rates.unavailable)) no disponible."
    }
}

/// BQ-08 (Kevin): si mostrar la fila cambia cuantas selecciones terminan en queja o en cambiar de local
private struct BQ08Section: View {
    let metrics: BQ08Metrics
    var body: some View {
        QuestionCard(title: "BQ-08 · ¿Ayuda mostrar la fila?", answer: answer,
                     note: "Selecciones con \(metrics.followUpMinutes) min de seguimiento completo. Una diferencia no prueba causalidad.") {
            BarList(parts: [
                BarPart(label: "Sin indicador", value: metrics.groups.control.completeSelections, color: Palette.cyan),
                BarPart(label: "Con indicador", value: metrics.groups.treatment.completeSelections, color: Palette.green),
            ])
        }
    }
    // tasa de queja o cambio por grupo, o por que todavia no hay
    private var answer: String {
        guard let difference = metrics.rateDifference,
              let without = metrics.groups.control.outcomeRate, let with = metrics.groups.treatment.outcomeRate else {
            return "Muestra insuficiente: se necesitan \(metrics.minimumSampleSize) selecciones completas por grupo."
        }
        return "Queja o cambio de local: \(percent(without)) sin indicador vs \(percent(with)) con indicador (\(String(format: "%+.1f", difference * 100)) pts)."
    }
}

/// actividad de los menus del restaurante: que hacen los estudiantes despues de ver un menu, como embudo
private struct EngagementSection: View {
    let summary: PerformanceSummary
    var body: some View {
        QuestionCard(title: "Actividad · ¿Qué hacen después de ver un menú?", answer: answer,
                     note: "Guardados \(summary.savedMenus) · indicaciones \(summary.locationOpens) · reportes \(summary.reports). Llegadas autorreportadas, no compras.") {
            BarList(parts: [
                BarPart(label: "Vieron", value: summary.impressions, color: Palette.yellow),
                BarPart(label: "Abrieron", value: summary.detailOpens, color: Palette.cyan),
                BarPart(label: "Eligieron", value: summary.selections, color: Palette.green),
                BarPart(label: "Llegaron", value: summary.reportedArrivals, color: Palette.coral),
            ])
        }
    }
    private var answer: String {
        let sample = summary.sampleSize.map { " en \($0) sesiones" } ?? ""
        guard let rates = summary.rates else { return "\(summary.impressions) tarjetas vistas\(sample). Muestra insuficiente para porcentajes." }
        return "\(summary.impressions) tarjetas vistas\(sample): \(percent(rates.detailOpenRate)) abren el detalle y \(percent(rates.selectionRate)) eligen."
    }
}
