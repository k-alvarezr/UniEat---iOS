import SwiftUI

/// pestañas segun el rol que dijo el server, ocultarlas es solo comodidad
/// igual la api revisa el rol en cada llamada
struct MainTabsView: View {
    @EnvironmentObject private var store: AppStore
    // el rol para decidir las pestañas sale de SessionStore
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        // selection deja cambiar de pestaña desde afuera, por ejemplo el boton de perfil de la cabecera
        TabView(selection: $store.selectedTab) {
            TodayFeedView()
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

/// perfil, datos de la cuenta, lo de cada rol, guardados y cerrar sesion
struct ProfileView: View {
    // perfil lee sesion, guardados y cola de reportes por ProfileViewModel
    @EnvironmentObject private var store: ProfileViewModel
    @State private var confirmingSignOut = false   // aviso si hay reportes sin mandar antes de cerrar sesion

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
                    if store.canJoinPilot {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Participar en la evaluación del indicador de fila", isOn: Binding(
                                    get: { store.pilotEnabled }, set: store.setPilotEnabled))
                                Text("En algunas sesiones verás el indicador y en otras no. Tus elecciones y reportes ayudarán a evaluar su utilidad. Puedes dejar de participar aquí.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let message = store.pilotMessage { Text(message).font(.footnote) }
                            }
                        }
                    }
                    if let error = store.accountError {
                        Text(error).font(.footnote)
                        Button("Actualizar cuenta") { Task { await store.refreshAccount() } }
                    }
                    if let error = store.storageError { Text(error).font(.footnote).foregroundStyle(Palette.coral) }
                    // reportes guardados en el celular: los que esperan red y los que el server rechazo
                    if store.reports.pendingReportCount + store.reports.needsReviewCount > 0 {
                        if store.reports.pendingReportCount > 0 {
                            Text("Reportes por enviar: \(store.reports.pendingReportCount)").font(.footnote)
                        }
                        if store.reports.needsReviewCount > 0 {
                            Text("Reportes por revisar: \(store.reports.needsReviewCount)").font(.footnote)
                        }
                        if let message = store.reports.syncMessage { Text(message).font(.footnote) }
                        Button("Reintentar reportes pendientes") { Task { await store.retryReports() } }
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
                    // si hay reportes sin mandar se pregunta antes, al cerrar sesion se borran del celular
                    SolidButton(title: "Cerrar sesión", icon: "rectangle.portrait.and.arrow.right", color: Palette.yellow) {
                        if store.unsentReports > 0 {
                            confirmingSignOut = true
                        } else {
                            Task { await store.signOut() }
                        }
                    }
                    .disabled(store.isSigningOut)
                    .confirmationDialog("Tienes \(store.unsentReports) reporte(s) sin enviar. Se intentarán enviar ahora; si no hay conexión se borrarán del celular.",
                                        isPresented: $confirmingSignOut, titleVisibility: .visible) {
                        Button("Cerrar sesión", role: .destructive) { Task { await store.signOut() } }
                        Button("Cancelar", role: .cancel) {}
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
