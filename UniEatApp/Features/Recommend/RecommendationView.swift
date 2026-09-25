import SwiftUI
import UniEatCore

struct RecommendationView: View {
    @EnvironmentObject private var store: AppStore
    @State private var index = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "UniEat · Elige por mí")
                DemoNotice()
                Sticker(text: "MODO RÁPIDO", color: Palette.yellow, icon: "sparkles")
                Text("Elige por mí ⚡")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                Text("El sorteo inteligente respeta tus filtros activos.")
                    .font(.subheadline)
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FILTROS APLICADOS")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                        Text("Presupuesto: \((store.filters.budgetCop ?? 20_000).cop) · Tiempo: \(store.filters.availableMinutes ?? 40) min")
                        Text("Zona: \(store.filters.area ?? "Todas") · Dieta: \(store.filters.diet ?? "Todas")")
                        Text("\(store.rankedMenus.count) opciones compatibles")
                            .font(.caption.weight(.bold))
                            .padding(7)
                            .background(Palette.cyan.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if store.rankedMenus.isEmpty {
                    EmptyFeedView()
                } else {
                    let menu = store.rankedMenus[index % store.rankedMenus.count]
                    SurfaceCard {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 52))
                            Text("Hoy prueba aquí")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                            Text("La opción cumple tus restricciones declaradas. Revisa la información estimada antes de ir.")
                                .font(.subheadline).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 16))
                    MenuCard(menu: menu, explanation: store.explanation(for: menu), pendingReports: store.pendingReports(for: menu),
                             assessment: PublicationAssessment(menu: menu))
                    SolidButton(title: "Elegir otra opción", icon: "arrow.clockwise", color: Palette.yellow) {
                        index += 1
                    }
                    NavigationLink(destination: MenuDetailView(menu: menu)) {
                        Text("Ver publicación completa  →")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Palette.coral, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationBarTitleDisplayMode(.inline)
    }
}
