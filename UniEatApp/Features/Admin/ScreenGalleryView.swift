import SwiftUI
import UniEatCore

/// atajo de admin a todas las pantallas, las que necesitan un menu usan uno real del feed
/// asi que solo salen si hay alguno publicado
struct ScreenGalleryView: View {
    @EnvironmentObject private var store: FeedViewModel
    @State private var reportMenu: DailyMenu?

    private var exampleMenu: DailyMenu? {
        store.menus.first(where: { !$0.hasWaitEvidence }) ?? store.menus.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BrandHeader(title: "Todas las pantallas")
                Text("Atajo a todas las pantallas de la app").font(.rounded(24))
                Text("Las pantallas de restaurante se pueden explorar aquí desde cualquier rol.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                row("01", "Hoy · Menús", icon: "fork.knife") { FeedContent() }
                row("02", "Filtros", icon: "slider.horizontal.3") { FiltersView() }
                row("03", "Elige por mí", icon: "sparkles") { RecommendationView() }
                row("04", "Publicar menú", icon: "plus.circle") { PublishView() }
                row("05", "Sin conexión", icon: "wifi.slash") { OfflineFeedView() }
                row("06", "Rendimiento", icon: "chart.bar") { PerformanceView() }
                if let menu = exampleMenu {
                    row("07", "Detalle del menú", icon: "doc.text.magnifyingglass") { MenuDetailView(menu: menu) }
                    Button { reportMenu = menu } label: {
                        tile("08", "Reportar un cambio", icon: "exclamationmark.bubble")
                    }
                    .buttonStyle(.plain)
                    row("09", "Espera sin evidencia", icon: "hourglass") { InsufficientQueueEvidenceView(menu: menu) }
                } else {
                    Text("Publica un menú para ver detalle, reporte y espera.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationTitle("Todas las pantallas")
        .connectionStatus(.gallery)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reportMenu) { menu in ReportSheet(menu: menu) }
    }

    private func row<Destination: View>(
        _ number: String, _ title: String, icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            tile(number, title, icon: icon)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ number: String, _ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Sticker(text: number, color: Palette.yellow)
            Label(title, systemImage: icon)
                .font(.rounded(15))
            Spacer()
            Image(systemName: "chevron.right")
        }
        .foregroundStyle(Palette.ink)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.ink, lineWidth: 2))
    }
}
