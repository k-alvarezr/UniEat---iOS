import SwiftUI
import UniEatCore

struct TodayFeedView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrandHeader(title: "UniEat · Hoy")
                        DemoNotice()
                        HStack(spacing: 8) {
                            Sticker(text: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                                    color: Palette.yellow, icon: "calendar")
                            Spacer()
                            if let budget = store.filters.budgetCop {
                                Sticker(text: "Hasta \(budget.cop)", color: Palette.green)
                            }
                        }
                        if store.isOffline {
                            OfflineNotice(cachedAt: store.cachedAt)
                        }
                        NavigationLink(destination: RecommendationView()) {
                            HStack {
                                Image(systemName: "sparkles")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("¿SORTEAR AHORA?").fontWeight(.heavy)
                                    Text("Una opción que cumple tus filtros")
                                        .font(.caption)
                                }
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .foregroundStyle(Palette.ink)
                            .padding(13)
                            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
                        }
                        HStack {
                            Text("Menús vigentes")
                                .font(.system(size: 25, weight: .heavy, design: .rounded))
                            Spacer()
                            NavigationLink(destination: FiltersView()) {
                                Label("Filtros", systemImage: "slider.horizontal.3")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                        }
                        if store.rankedMenus.isEmpty {
                            EmptyFeedView()
                        } else {
                            ForEach(store.rankedMenus) { menu in
                                NavigationLink(destination: MenuDetailView(menu: menu)) {
                                    MenuCard(menu: menu, explanation: store.explanation(for: menu), pendingReports: store.pendingReports(for: menu),
                                             assessment: PublicationAssessment(menu: menu, at: timeline.date))
                                }
                                .buttonStyle(.plain)
                                .onAppear { store.track("feed_impression", menu: menu) }
                            }
                        }
                        NavigationLink(destination: NoMenuPublishedView()) {
                            Label("Ver ejemplo: local sin menú del día", systemImage: "storefront")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.vertical, 10)
                    }
                    .padding(16)
                }
            }
            .background(Palette.cream)
            .navigationBarHidden(true)
        }
    }
}

struct MenuCard: View {
    let menu: DailyMenu
    let explanation: String
    let pendingReports: Int
    let assessment: PublicationAssessment

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                FoodArtwork(name: menu.establishmentName)
                    .frame(height: 130)
                HStack(alignment: .firstTextBaseline) {
                    Text(menu.establishmentName)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                    Spacer()
                    Sticker(text: menu.lowestPriceCop.cop, color: Palette.yellow)
                }
                Text(menu.title).font(.system(size: 14, weight: .bold, design: .rounded))
                HStack(spacing: 7) {
                    Sticker(text: menu.area, color: Palette.cyan, icon: "mappin")
                    if let wait = menu.waitMinutes, menu.hasWaitEvidence {
                        Sticker(text: "~\(wait) min de fila", color: Palette.green, icon: "clock")
                    } else {
                        Sticker(text: "Fila sin datos", color: Palette.cream, icon: "clock")
                    }
                }
                if pendingReports > 0 {
                    Label("\(pendingReports) reporte(s) pendiente(s) de verificar", systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(Palette.coral)
                }
                if assessment.state == .expiring {
                    Label("Menú por vencer", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(Palette.coral)
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Palette.ink)
    }
}

struct FoodArtwork: View {
    let name: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.yellow, Palette.coral.opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.45)).frame(width: 140).offset(x: 95, y: -40)
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(Palette.ink.opacity(0.75))
            Text(name.uppercased())
                .font(.system(size: 12, weight: .black, design: .rounded))
                .padding(7)
                .background(Palette.paper, in: Capsule())
                .offset(x: -75, y: 45)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel("Ilustración de \(name)")
    }
}

struct OfflineNotice: View {
    let cachedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sin conexión · vista guardada").fontWeight(.heavy)
                Text("Última carga: \(cachedAt.formatted(date: .abbreviated, time: .shortened)). Los menús vencidos se ocultan.")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
    }
}

struct EmptyFeedView: View {
    var body: some View {
        SurfaceCard {
            VStack(spacing: 10) {
                Image(systemName: "fork.knife.circle").font(.system(size: 48))
                Text("No hay menús que cumplan estos filtros")
                    .font(.headline)
                Text("Prueba otro presupuesto, zona o preferencia de dieta.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct NoMenuPublishedView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                BrandHeader(title: "Sin menú del día")
                Spacer(minLength: 40)
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 70))
                    .frame(width: 132, height: 132)
                    .background(Palette.cream, in: Circle())
                Text("Este local no ha publicado el menú de hoy")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("La ausencia de menú no significa que esté cerrado. Puedes revisar otras opciones cercanas.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Palette.cream)
    }
}
