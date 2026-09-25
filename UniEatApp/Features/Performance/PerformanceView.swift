import SwiftUI
import UniEatCore

struct PerformanceView: View {
    @EnvironmentObject private var store: AppStore
    @State private var days = 7

    private var summary: PerformanceSummary { store.performance(days: days) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "UniEat · Rendimiento")
                DemoNotice()
                Text("Señales de interés")
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                Text("Métricas de interacción dentro de esta sesión demo. No representan ventas ni visitas verificadas.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Período", selection: $days) {
                    Text("Últimos 7 días").tag(7)
                    Text("28 días").tag(28)
                }
                .pickerStyle(.segmented)
                if store.ownMenus.isEmpty {
                    SurfaceCard {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.bar.xaxis").font(.largeTitle)
                            Text("Publica tu primer menú para ver actividad")
                                .font(.headline)
                            Text("Las métricas aparecerán cuando alguien interactúe con tu publicación en esta demo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        MetricTile(number: summary.impressions, title: "Impresiones", detail: "Tarjetas vistas", color: Palette.yellow)
                        MetricTile(number: summary.detailOpens, title: "Aperturas", detail: "Detalle abierto", color: Palette.cyan)
                        MetricTile(number: summary.selections, title: "Selecciones", detail: "Menú elegido", color: Palette.green)
                        MetricTile(number: summary.reportedArrivals, title: "Llegadas", detail: "Reportadas por usuarios", color: Palette.coral)
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
