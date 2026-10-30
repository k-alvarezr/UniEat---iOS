import SwiftUI

@main
struct UniEatApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            // se inyecta el store y cada viewmodel por separado
            // asi cada pantalla pide con @EnvironmentObject solo el que usa
            RootView()
                .environmentObject(store)
                .environmentObject(store.session)
                .environmentObject(store.feed)
                .environmentObject(store.saved)
                .environmentObject(store.authentication)
                .environmentObject(store.filters)
                .environmentObject(store.recommendation)
                .environmentObject(store.publication)
                .environmentObject(store.performance)
                .environmentObject(store.profile)
                .environmentObject(store.establishments)
                .environmentObject(store.approvals)
                .environmentObject(store.roles)
                .environmentObject(store.pilot)
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
                AuthView()
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
