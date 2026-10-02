import SwiftUI
import UniEatCore

struct SavedMenusView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: "Menús guardados")
                Text("Se guardan en este dispositivo para tu cuenta. La vigencia y los reportes se actualizan al abrir el detalle con conexión.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.savedMenus.isEmpty {
                    ContentUnavailableView("Sin menús guardados", systemImage: "bookmark",
                                           description: Text("Abre un menú y toca Guardar menú."))
                } else {
                    ForEach(store.savedMenus) { entry in
                        NavigationLink(destination: MenuDetailView(menu: entry.menu)) {
                            SurfaceCard {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.menu.establishmentName).font(.headline)
                                    Text(entry.menu.title)
                                    Text("Guardado: \(SpanishPresentation.dateAndTime(entry.savedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !entry.menu.isActive(at: .now) {
                                        Text("La copia guardada ya venció; consulta el detalle para ver su estado actual.")
                                            .font(.caption).foregroundStyle(Palette.coral)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationTitle("Guardados")
    }
}
