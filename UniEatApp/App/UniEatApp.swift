import SwiftUI

@main
struct UniEatApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            // se inyecta el container y cada viewmodel por separado
            // asi cada pantalla pide con @EnvironmentObject solo el que usa
            RootView()
                .environmentObject(container)
                .environmentObject(container.session)
                .environmentObject(container.connectivity)
                .environmentObject(container.todayFeed)
                .environmentObject(container.saved)
                .environmentObject(container.login)
                .environmentObject(container.filters)
                .environmentObject(container.pickForMe)
                .environmentObject(container.publishMenu)
                .environmentObject(container.performance)
                .environmentObject(container.profile)
                .environmentObject(container.establishments)
                .environmentObject(container.approvals)
                .environmentObject(container.roles)
                .environmentObject(container.reportHistory)
                .environmentObject(container.pilot)
                .environment(\.locale, SpanishPresentation.locale)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        Group {
            if session.profile == nil {
                LoginView()
            } else {
                MainTabsView()
            }
        }
        // cada sesion tiene una generacion distinta, al cambiarla se rehacen todas las pantallas
        // asi no queda nada en pantalla del usuario anterior
        .id(session.generation)
        .tint(Palette.ink)
        .font(BrandFont.body)
    }
}
