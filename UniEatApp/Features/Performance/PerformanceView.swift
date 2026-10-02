import SwiftUI
import UniEatCore

struct PerformanceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var days = 7

    var body: some View {
        Group {
            if store.isAdmin {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "UniEat · Rendimiento")
                        Text("Panel global de iOS · BQ-03, BQ-04 y actividad en el mismo período.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        PeriodPicker(days: $days)
                        if let error = store.performanceError {
                            PerformanceErrorCard(message: error) { Task { await store.loadPerformance(days: days) } }
                        }
                        if let snapshot = store.adminDashboard[days] {
                            Text("Actualizado: \(SpanishPresentation.dateAndTime(snapshot.generatedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                            BQ03Section(metrics: snapshot.bq03)
                            BQ04Section(metrics: snapshot.bq04)
                            EngagementSection(summary: snapshot.engagement)
                        } else if store.performanceError == nil {
                            ProgressView("Cargando métricas del servidor…")
                        }
                    }
                    .padding(16)
                }
                .background(Palette.cream)
                .task(id: days) {
                    while !Task.isCancelled {
                        await store.loadPerformance(days: days)
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                }
            } else {
                ContentUnavailableView("Solo administradores", systemImage: "lock.fill",
                                       description: Text("Inicia sesión con una cuenta administradora para ver el tablero global."))
            }
        }
    }
}

struct RestaurantPerformanceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var days = 7

    var body: some View {
        Group {
            if store.isRestaurant {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "Actividad de mis menús")
                        DemoNotice()
                        Text("Solo publicaciones de tus establecimientos aprobados. Las cifras son actividad iOS, no ventas ni visitas verificadas.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        PeriodPicker(days: $days)
                        if let error = store.performanceError {
                            PerformanceErrorCard(message: error) { Task { await store.loadPerformance(days: days) } }
                        }
                        if !store.isRemote || store.restaurantPerformance[days] != nil {
                            EngagementSection(summary: store.performance(days: days))
                        } else if store.performanceError == nil {
                            ProgressView("Cargando métricas del servidor…")
                        }
                    }
                    .padding(16)
                }
                .background(Palette.cream)
                .task(id: days) {
                    guard store.isRemote else { return }
                    while !Task.isCancelled {
                        await store.loadPerformance(days: days)
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                }
            } else {
                ContentUnavailableView("Solo restaurantes", systemImage: "lock.fill")
            }
        }
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

private struct BQ04Section: View {
    let metrics: BQ04Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BQ-04 · Vigencia y cambios").font(.title3.bold())
            Text("Estados y avisos mostrados al consultar detalles desde iOS; un detalle puede tener más de un aviso.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                MetricTile(number: "\(metrics.detailRequests)", title: "Consultas", detail: "Detalles solicitados", color: Palette.yellow)
                MetricTile(number: "\(metrics.activeShown)", title: "Vigentes", detail: "Estado activo mostrado", color: Palette.green)
                MetricTile(number: "\(metrics.expiringShown)", title: "Por vencer", detail: "Estado próximo a vencer", color: Palette.yellow)
                MetricTile(number: "\(metrics.expiredShown)", title: "Vencidos", detail: "Estado vencido", color: Palette.coral)
                MetricTile(number: "\(metrics.closedShown)", title: "Cerrados", detail: "Publicación cerrada", color: Palette.coral)
                MetricTile(number: "\(metrics.pendingNoticesShown)", title: "Avisos pendientes", detail: "Detalles con cambio por revisar", color: Palette.cyan)
                MetricTile(number: "\(metrics.confirmedNoticesShown)", title: "Avisos confirmados", detail: "Detalles con cambio confirmado", color: Palette.green)
            }
        }
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
                Text(number).font(.system(size: 28, weight: .black, design: .rounded))
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(color, in: RoundedRectangle(cornerRadius: 16))
    }
}
