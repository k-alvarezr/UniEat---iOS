import SwiftUI
import UniEatCore

struct OfflineFeedView: View {
    @EnvironmentObject private var store: AppStore
    @State private var retryMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandHeader(title: "UniEat · Sin conexión")
                    DemoNotice()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Sin conexión", systemImage: "wifi.slash")
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                        Text("Mostrando datos guardados el \(SpanishPresentation.dateAndTime(store.cachedAt)).")
                            .font(.subheadline.weight(.semibold))
                        Text("Los menús vencidos se ocultan aunque sigan en la copia local.")
                            .font(.subheadline)
                        SolidButton(title: "Reintentar conexión", icon: "arrow.clockwise", color: Palette.paper) {
                            Task {
                                await store.refresh()
                                if store.isConnected { store.forceOffline = false }
                                retryMessage = store.isOffline
                                    ? "La copia local sigue disponible. No hay conexión nueva."
                                    : "La vista local se actualizó."
                            }
                        }
                        if let retryMessage {
                            Text(retryMessage).font(.caption.weight(.semibold))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 2))

                    HStack {
                        Sticker(text: "Filtros guardados", color: Palette.cream, icon: "slider.horizontal.3")
                        if let budget = store.filters.budgetCop {
                            Sticker(text: "Hasta \(budget.cop)", color: Palette.cyan)
                        }
                    }
                    Text("Menús disponibles en esta copia")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                    if store.rankedMenus.isEmpty {
                        EmptyFeedView()
                    } else {
                        ForEach(store.rankedMenus) { menu in
                            NavigationLink(destination: MenuDetailView(menu: menu)) {
                                MenuCard(menu: menu, explanation: store.explanation(for: menu),
                                         pendingReports: store.pendingReports(for: menu),
                                         assessment: PublicationAssessment(menu: menu, at: timeline.date))
                                    .opacity(0.78)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Los datos de ejemplo de esta versión son locales; cuando exista el servicio compartido, esta pantalla mostrará la última descarga real.")
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
}
