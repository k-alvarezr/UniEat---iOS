import SwiftUI
import UniEatCore

/// pestaña rendimiento solo admin, BQ-03 BQ-04 y actividad de ios en el mismo panel
struct PerformanceView: View {
    // las metricas viven en PerformanceViewModel, antes en el AppStore viejo
    @EnvironmentObject private var store: PerformanceViewModel

    var body: some View {
        Group {
            if store.isAdmin {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "UniEat · Rendimiento")
                        Text("Panel global de iOS · BQ-03, BQ-04 y actividad en el mismo período.")
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
                            EngagementSection(summary: snapshot.engagement)
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
                        BrandHeader(title: "Actividad de mis menús")
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

/// seccion BQ-08 del tablero (piloto de Kevin): compara con y sin indicador de fila
/// cuantas selecciones terminaron en queja de fila o en cambiar de local en los 10 minutos siguientes
private struct BQ08Section: View {
    let metrics: BQ08Metrics
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("BQ-08 · ¿Ayuda mostrar la fila?").font(.rounded(21))
                Text("Comparamos selecciones seguidas por una queja de fila o por elegir otro local en los siguientes diez minutos.")
                    .font(.subheadline)
                group("Sin indicador", metrics.groups.control, color: Palette.cyan)
                group("Con indicador", metrics.groups.treatment, color: Palette.green)
                if let difference = metrics.rateDifference {
                    Text("Diferencia observada con − sin indicador: \(String(format: "%+.1f", difference * 100)) puntos porcentuales.")
                } else {
                    Text("Muestra insuficiente: se necesitan al menos \(metrics.minimumSampleSize) selecciones con ventana completa en cada variante.")
                }
                Text("Cada sesión aporta una selección inicial con exposición registrada. Las ventanas en curso se excluyen de las tasas. Reportar minutos de espera no equivale a una queja. Una diferencia observada no demuestra causalidad por sí sola.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func group(_ title: String, _ group: BQ08Metrics.Group, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text("Expuestas: \(group.exposedSessions) · completas: \(group.completeSelections) · en curso: \(group.incompleteSelections)")
                .font(.caption)
            Text("Resultado combinado: \(group.combinedOutcomes). Quejas: \(group.longLineOutcomes); cambios de local: \(group.switchOutcomes).")
                .font(.caption)
            if let rate = group.outcomeRate {
                ProgressView(value: rate).tint(color)
                Text("\(Int((rate * 100).rounded())) % de selecciones elegibles").font(.caption.weight(.bold))
            } else { Text("Tasa pendiente de muestra suficiente").font(.caption) }
        }
        .padding(10).background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
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

private struct BQ03Section: View {
    let metrics: BQ03Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BQ-03 · Búsqueda contextual").font(.title3.bold())
            Text("Consultas del feed iOS; la copia sin conexión no genera consultas nuevas.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                MetricTile(number: "\(metrics.feedRequests)", title: "Consultas", detail: "Solicitudes al feed", color: Palette.yellow)
                MetricTile(number: "\(metrics.contextualRequests)", title: "Con filtros", detail: "Presupuesto, dieta, zona, tiempo o pago", color: Palette.cyan)
                MetricTile(number: "\(metrics.successfulRequests)", title: "Exitosas", detail: "Consultas respondidas", color: Palette.green)
                MetricTile(number: "\(metrics.failedRequests)", title: "Fallidas", detail: "Errores registrados", color: Palette.coral)
                MetricTile(number: "\(metrics.zeroResultRequests)", title: "Sin resultados", detail: "Consultas exitosas sin menú compatible", color: Palette.yellow)
                MetricTile(number: String(format: "%.1f", metrics.averageResults), title: "Promedio", detail: "Menús válidos por consulta exitosa", color: Palette.cyan)
            }
        }
    }
}

/// resumen de BQ-04 para que el admin se de una idea, el detalle completo esta en el tablero html
private struct BQ04Section: View {
    let metrics: BQ04Metrics
    // vencidos + cerrados, si el back aun no lo manda se suma aca
    private var unavailable: Int { metrics.unavailableShown ?? metrics.expiredShown + metrics.closedShown }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BQ-04 · ¿Los menús que se abren están vigentes?").font(.title3.bold())
            Text(summary).font(.subheadline)
            if metrics.detailRequests > 0 { ValidityBar(active: metrics.activeShown, expiring: metrics.expiringShown, unavailable: unavailable) }
            if let rates = metrics.rates {
                Text("\(percent(rates.pendingNotice)) con cambio sin revisar · \(percent(rates.confirmedNotice)) con cambio confirmado")
                    .font(.caption).foregroundStyle(.secondary)
            } else if metrics.detailRequests > 0 {
                Text("Muestra insuficiente para porcentajes, se necesitan 20 consultas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    // la respuesta en una frase, con porcentajes solo si el server los mando
    private var summary: String {
        let menus = metrics.distinctMenus.map { " de \($0) menús" } ?? ""
        guard let rates = metrics.rates else {
            return "\(metrics.detailRequests) consultas\(menus): \(metrics.activeShown) vigentes, \(metrics.expiringShown) por vencer, \(unavailable) no disponibles."
        }
        return "\(metrics.detailRequests) consultas\(menus): \(percent(rates.active)) vigente, \(percent(rates.expiring)) por vencer, \(percent(rates.unavailable)) no disponible."
    }
    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }
}

/// barra apilada vigente / por vencer / no disponible sobre el total de consultas
private struct ValidityBar: View {
    let active: Int
    let expiring: Int
    let unavailable: Int
    var body: some View {
        let total = CGFloat(max(active + expiring + unavailable, 1))
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Palette.green.frame(width: proxy.size.width * CGFloat(active) / total)
                Palette.yellow.frame(width: proxy.size.width * CGFloat(expiring) / total)
                Palette.coral.frame(width: proxy.size.width * CGFloat(unavailable) / total)
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("\(active) vigentes, \(expiring) por vencer, \(unavailable) no disponibles")
    }
}

private struct EngagementSection: View {
    let summary: PerformanceSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Actividad de menús").font(.title3.bold())
            Text("Todas las métricas corresponden a los últimos \(summary.periodDays) días.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                MetricTile(number: "\(summary.detailOpens)", title: "Aperturas", detail: "Detalle abierto", color: Palette.cyan)
                MetricTile(number: "\(summary.savedMenus)", title: "Guardados", detail: "Personas que guardaron una versión", color: Palette.yellow)
                MetricTile(number: "\(summary.locationOpens)", title: "Indicaciones", detail: "Aperturas de ruta desde el detalle", color: Palette.green)
                MetricTile(number: "\(summary.reports)", title: "Reportes", detail: "Disponibilidad, precio, fila o ubicación", color: Palette.coral)
                MetricTile(number: "\(summary.impressions)", title: "Impresiones", detail: "Tarjetas vistas por sesión y versión", color: Palette.yellow)
                MetricTile(number: "\(summary.selections)", title: "Selecciones", detail: "Elecciones explícitas, no compras", color: Palette.green)
                MetricTile(number: "\(summary.reportedArrivals)", title: "Llegadas", detail: "Autorreportadas, no verificadas", color: Palette.coral)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 6) {
                    if let count = summary.sampleSize { Text("Muestra: \(count) sesiones con interacción.") }
                    if let rates = summary.rates {
                        Text("Aperturas por impresión: \(Int((rates.detailOpenRate * 100).rounded())) %")
                        Text("Selecciones por impresión: \(Int((rates.selectionRate * 100).rounded())) %")
                    } else if summary.insufficientData == true {
                        Text("Muestra insuficiente para mostrar tasas fiables.")
                    }
                    Text("Guardados cuenta personas que tocaron Guardar durante el período, aunque luego quiten el menú de su lista.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MetricTile: View {
    let number: String
    let title: String
    let detail: String
    let color: Color
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(number).font(.rounded(28, .black))
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(color, in: RoundedRectangle(cornerRadius: 16))
    }
}
