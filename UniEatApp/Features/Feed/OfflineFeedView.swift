import SwiftUI
import UniEatCore

/// sin internet, muestra la ultima copia con su fecha y oculta lo vencido
struct OfflineFeedView: View {
    @EnvironmentObject private var store: FeedViewModel
    @State private var retryMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandHeader(title: "UniEat · Sin conexión")
                    statusCard
                    HStack {
                        Sticker(text: "Filtros guardados", color: Palette.cream, icon: "slider.horizontal.3")
                        if let budget = store.filters.budgetCop {
                            Sticker(text: "Hasta \(budget.cop)", color: Palette.cyan)
                        }
                    }
                    Text("Menús disponibles en esta copia").font(.rounded(22))
                    if store.visibleMenus.isEmpty {
                        EmptyFeedView()
                    } else {
                        ForEach(store.visibleMenus) { menu in
                            NavigationLink(destination: MenuDetailView(menu: menu)) {
                                MenuCard(menu: menu, at: store.clock.now).opacity(0.78)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Es la última copia descargada; puede haber cambios desde entonces.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Palette.cream)
            .navigationTitle("Sin conexión")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sin conexión", systemImage: "wifi.slash").font(.rounded(25))
            Text(store.hasSnapshot ? "Mostrando datos guardados el \(SpanishPresentation.dateAndTime(store.fetchedAt))" : "Aún no hay una copia descargada para estos filtros.")
                .font(.subheadline.weight(.semibold))
            Text("Los menús vencidos se ocultan aunque sigan en la copia local.")
                .font(.subheadline)
            SolidButton(title: "Reintentar conexión", icon: "arrow.clockwise", color: Palette.paper) {
                Task { await retry() }
            }
            if let retryMessage {
                Text(retryMessage).font(.caption.weight(.semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 2))
    }

    private func retry() async {
        await store.refresh(force: true)
        retryMessage = store.loadError ?? (store.isOffline
            ? "La copia local sigue disponible. No hay conexión nueva."
            : "La vista se actualizó.")
    }
}
