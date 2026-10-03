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
            } else {
                NavigationStack { RecommendationView() }
                    .tabItem { Label("Elige por mí", systemImage: "sparkles") }
            }
            if store.isAdmin {
                NavigationStack { PerformanceView() }
                    .tabItem { Label("Rendimiento", systemImage: "chart.bar.fill") }
            } else if store.isRestaurant {
                NavigationStack { RestaurantPerformanceView() }
                    .tabItem { Label("Mis métricas", systemImage: "chart.bar") }
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
                            Sticker(text: store.profile?.role == "admin" ? "Administrador" :
                                    (store.isRestaurant ? "Restaurante" : "Estudiante"), color: Palette.green)
                            Text("Las preferencias de presupuesto, dieta, tiempo y zona se conservan al volver a la lista de menús.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.isRemote {
                        if store.isAdmin {
                            AdminApprovalsView()
                            AdminRolesView()
                        } else {
                            EstablishmentManagementView()
                        }
                    }
                    Text("La información guardada muestra cuándo se obtuvo y descarta menús vencidos incluso sin conexión.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // Atajo de revisión: solo administradores con sesión real (issue #15).
                    if store.isAdmin {
                        NavigationLink(destination: ScreenGalleryView()) {
                            Label("Atajo a todas las pantallas de la app", systemImage: "square.grid.2x2")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                                .foregroundStyle(Palette.ink)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
                        }
                    }
                    NavigationLink(destination: SavedMenusView()) {
                        Label("Menús guardados (\(store.savedMenus.count))", systemImage: "bookmark.fill")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
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
