import SwiftUI
import UniEatCore

/// elige por mi, muestra la mejor opcion con los filtros y deja pasar a la siguiente
/// el orden y el motivo vienen del server, aca solo se recorre la lista
struct RecommendationView: View {
    @EnvironmentObject private var store: RecommendationViewModel

    private var options: [DailyMenu] { store.visibleMenus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "UniEat · Elige por mí")
                Sticker(text: "MODO RÁPIDO", color: Palette.yellow, icon: "sparkles")
                Text("Elige por mí ⚡").font(.rounded(28, .black))
                Text("Las opciones se ordenan según tus filtros y la información disponible.")
                    .font(.subheadline)
                filtersSummary
                if options.isEmpty {
                    EmptyFeedView()
                } else {
                    recommendation(options[store.index % options.count])
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtersSummary: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("FILTROS APLICADOS").font(.rounded(11))
                Text("Presupuesto: \((store.filters.budgetCop ?? 20_000).cop) · Tiempo: \(store.filters.availableMinutes ?? 40) min")
                Text("Zona: \(store.filters.area ?? "Todas") · Dieta: \(SpanishPresentation.diet(store.filters.diet))")
                Text("\(options.count) opciones compatibles")
                    .font(.caption.weight(.bold))
                    .padding(7)
                    .background(Palette.cyan.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func recommendation(_ menu: DailyMenu) -> some View {
        SurfaceCard {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 52))
                Text("Hoy prueba aquí").font(.rounded(22))
                Text("La opción cumple tus restricciones declaradas. Revisa la información estimada antes de ir.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 16))
        MenuCard(menu: menu)
        SolidButton(title: "Ver siguiente opción", icon: "arrow.clockwise", color: Palette.yellow) {
            store.next()
        }
        NavigationLink(destination: MenuDetailView(menu: menu)) {
            Text("Ver publicación completa  →")
                .font(.rounded(15))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.coral, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
                .foregroundStyle(Palette.ink)
        }
    }
}
