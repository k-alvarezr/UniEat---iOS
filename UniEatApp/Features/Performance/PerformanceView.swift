import SwiftUI
import UniEatCore

struct PerformanceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var days = 7
    private var summary: PerformanceSummary {
        store.performance(days: days)
    }

    var body: some View {
        Group {
        if store.isAdmin {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "UniEat · Rendimiento")
                DemoNotice()
                Text("Señales de interés")
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                Text("Interacciones iOS agregadas por el servidor. No representan ventas ni visitas verificadas.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Período", selection: $days) {
                    Text("Últimos 7 días").tag(7)
                    Text("28 días").tag(28)
                }
                .pickerStyle(.segmented)
                if store.remotePerformance[days] == nil {
                    ProgressView("Cargando métricas del servidor…")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        MetricTile(number: summary.impressions, title: "Impresiones", detail: "Tarjetas vistas", color: Palette.yellow)
                        MetricTile(number: summary.detailOpens, title: "Aperturas", detail: "Detalle abierto", color: Palette.cyan)
                        MetricTile(number: summary.selections, title: "Selecciones", detail: "Menú elegido", color: Palette.green)
                        MetricTile(number: summary.reportedArrivals, title: "Llegadas", detail: "Reportadas por usuarios", color: Palette.coral)
                    }
                    if store.isRemote {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Lectura del período").font(.headline)
                                if let count = summary.sampleSize {
                                    Text("Muestra: \(count) sesiones con al menos una interacción.")
                                }
                                if let rates = summary.rates {
                                    Text("Apertura por impresión: \(Int((rates.detailOpenRate * 100).rounded())) %")
                                    Text("Selección por impresión: \(Int((rates.selectionRate * 100).rounded())) %")
                                } else if summary.insufficientData == true {
                                    Text("Aún no hay suficientes sesiones o impresiones para mostrar tasas fiables.")
                                }
                                Text("Una impresión es una sesión que vio una versión de la publicación; las llegadas son reportes, no visitas verificadas.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Actividad relativa")
                                .font(.headline)
                            bar("Impresiones", value: summary.impressions, maxValue: max(summary.impressions, 1), color: Palette.yellow)
                            bar("Aperturas", value: summary.detailOpens, maxValue: max(summary.impressions, 1), color: Palette.cyan)
                            bar("Selecciones", value: summary.selections, maxValue: max(summary.impressions, 1), color: Palette.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        // Con cuenta real las cifras vienen agregadas del servidor para el período elegido.
        .task(id: days) { await store.loadPerformance(days: days) }
        } else {
            ContentUnavailableView("Solo administradores", systemImage: "lock.fill",
                                   description: Text("Inicia sesión con una cuenta administradora para ver el rendimiento."))
        }
        }
    }

    private func bar(_ title: String, value: Int, maxValue: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text("\(value)") }
                .font(.caption.weight(.bold))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: max(4, geometry.size.width * CGFloat(value) / CGFloat(maxValue)), height: 14)
            }
            .frame(height: 14)
        }
    }
}

private struct MetricTile: View {
    let number: Int
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number)")
                    .font(.system(size: 31, weight: .black, design: .rounded))
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(color, in: RoundedRectangle(cornerRadius: 16))
    }
}
