import SwiftUI

struct MainTabsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            TodayFeedView()
                .tabItem { Label("Hoy", systemImage: "fork.knife") }
            if store.isRestaurant {
                PublishView()
                    .tabItem { Label("Publicar", systemImage: "plus.circle.fill") }
                NavigationStack { PerformanceView() }
                    .tabItem { Label("Rendimiento", systemImage: "chart.bar.fill") }
            } else {
                NavigationStack { RecommendationView() }
                    .tabItem { Label("Elige por mí", systemImage: "sparkles") }
            }
            ProfileView()
                .tabItem { Label("Perfil", systemImage: "person.crop.circle") }
        }
        .tint(Palette.ink)
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandHeader(title: "Mi perfil")
                    DemoNotice()
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.profile?.displayName ?? "")
                                .font(.system(size: 23, weight: .heavy, design: .rounded))
                            Sticker(text: store.isRestaurant ? "Restaurante" : "Estudiante", color: Palette.green)
                            Text("Las preferencias de presupuesto, dieta, tiempo y zona se conservan al volver al feed.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Toggle("Simular falta de conexión", isOn: $store.forceOffline)
                        .padding(14)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
                    Text("La información guardada muestra cuándo se obtuvo y descarta menús vencidos incluso sin conexión.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink(destination: ScreenGalleryView()) {
                        Label("Explorar las 10 pantallas de MS7", systemImage: "square.grid.2x2")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
                    }
                    SolidButton(title: "Cerrar sesión", icon: "rectangle.portrait.and.arrow.right", color: Palette.yellow) {
                        store.signOut()
                    }
                }
                .padding(16)
            }
            .background(Palette.cream)
            .navigationBarHidden(true)
        }
    }
}
