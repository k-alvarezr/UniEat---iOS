import SwiftUI

/// pestañas segun el rol que dijo el server, ocultarlas es solo comodidad
/// igual la api revisa el rol en cada llamada
struct MainTabsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        // selection deja cambiar de pestaña desde afuera, por ejemplo el boton de perfil de la cabecera
        TabView(selection: $store.selectedTab) {
            TodayFeedView()
                .tabItem { Label("Hoy", systemImage: "fork.knife") }
                .tag(AppTab.today)
            if store.isRestaurant {
                PublishView()
                    .tabItem { Label("Publicar", systemImage: "plus.circle.fill") }
                    .tag(AppTab.second)
            } else {
                NavigationStack { RecommendationView() }
                    .tabItem { Label("Elige por mí", systemImage: "sparkles") }
                    .tag(AppTab.second)
            }
            if store.isAdmin {
                NavigationStack { PerformanceView() }
                    .tabItem { Label("Rendimiento", systemImage: "chart.bar.fill") }
                    .tag(AppTab.metrics)
            } else if store.isRestaurant {
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

/// perfil, datos de la cuenta, lo de cada rol, guardados y cerrar sesion
struct ProfileView: View {
    @EnvironmentObject private var store: AppStore

    private var roleName: String {
        if store.profile?.role == "admin" { return "Administrador" }
        return store.isRestaurant ? "Restaurante" : "Estudiante"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandHeader(title: "Mi perfil", showsProfileButton: false)
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.profile?.displayName ?? "").font(.rounded(23))
                            Sticker(text: roleName, color: Palette.green)
                            Text("Las preferencias de presupuesto, dieta, tiempo y zona se conservan al volver a la lista de menús.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.isAdmin {
                        AdminApprovalsView()
                        AdminRolesView()
                    } else {
                        EstablishmentManagementView()
                    }
                    Text("La información guardada muestra cuándo se obtuvo y descarta menús vencidos incluso sin conexión.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.isAdmin {
                        NavigationLink(destination: ScreenGalleryView()) {
                            profileButton("Atajo a todas las pantallas de la app", icon: "square.grid.2x2", color: Palette.cyan)
                        }
                    }
                    NavigationLink(destination: SavedMenusView()) {
                        profileButton("Menús guardados (\(store.savedMenus.count))", icon: "bookmark.fill", color: Palette.paper)
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

    private func profileButton(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.rounded(15))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
    }
}
