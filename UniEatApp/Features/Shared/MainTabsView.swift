import SwiftUI

/// pestañas segun el rol que dijo el server, ocultarlas es solo comodidad
/// igual la api revisa el rol en cada llamada
struct MainTabsView: View {
    @EnvironmentObject private var store: AppContainer
    // el rol para decidir las pestañas sale de SessionStore
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        // selection deja cambiar de pestaña desde afuera, por ejemplo el boton de perfil de la cabecera
        TabView(selection: $store.selectedTab) {
            FeedView()
                .tabItem { Label("Hoy", systemImage: "fork.knife") }
                .tag(AppTab.today)
            if session.isRestaurant {
                PublishView()
                    .tabItem { Label("Publicar", systemImage: "plus.circle.fill") }
                    .tag(AppTab.second)
            } else {
                NavigationStack { RecommendationView() }
                    .tabItem { Label("Elige por mí", systemImage: "sparkles") }
                    .tag(AppTab.second)
            }
            if session.isAdmin {
                NavigationStack { PerformanceView() }
                    .tabItem { Label("Rendimiento", systemImage: "chart.bar.fill") }
                    .tag(AppTab.metrics)
            } else if session.isRestaurant {
                NavigationStack { RestaurantPerformanceView() }
                    .tabItem { Label("Mis métricas", systemImage: "chart.bar") }
                    .tag(AppTab.metrics)
            }
            ProfileView()
                .tabItem { Label("Perfil", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .tint(Palette.ink)
    }
}
