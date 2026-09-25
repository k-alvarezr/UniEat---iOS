import SwiftUI
import UniEatCore

/// A direct route to every MS7 view for reviewing the iOS prototype.
struct ScreenGalleryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingReport = false

    private var exampleMenu: DailyMenu {
        store.menus.first(where: { !$0.hasWaitEvidence }) ?? SampleMenus.all[1]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BrandHeader(title: "Pantallas MS7")
                Text("Recorre las diez vistas del prototipo")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text("Las pantallas de restaurante se pueden explorar aquí desde cualquier rol. Para guardar menús, entra como restaurante.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                row("01", "Hoy · Menús", icon: "fork.knife") { TodayFeedContent() }
                row("02", "Filtros", icon: "slider.horizontal.3") { FiltersView() }
                row("03", "Detalle del menú", icon: "doc.text.magnifyingglass") {
                    MenuDetailView(menu: exampleMenu)
                }
                row("04", "Elige por mí", icon: "sparkles") { RecommendationView() }
                row("05", "Publicar menú", icon: "plus.circle") { PublishView() }
                Button { showingReport = true } label: {
                    tile("06", "Reportar un cambio", icon: "exclamationmark.bubble")
                }
                .buttonStyle(.plain)
                row("07", "Sin conexión", icon: "wifi.slash") { OfflineFeedView() }
                row("08", "Sin menú publicado", icon: "storefront") { NoMenuPublishedView() }
                row("09", "Espera sin evidencia", icon: "hourglass") {
                    InsufficientQueueEvidenceView(menu: exampleMenu)
                }
                row("10", "Rendimiento", icon: "chart.bar") { PerformanceView(preview: true) }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationTitle("Pantallas MS7")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReport) { ReportSheet(menu: exampleMenu) }
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
                .font(.system(size: 15, weight: .heavy, design: .rounded))
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
