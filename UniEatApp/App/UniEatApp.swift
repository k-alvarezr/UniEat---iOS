import SwiftUI

@main
struct UniEatApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
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
        .id(session.generation)
        .tint(Palette.ink)
        .font(BrandFont.body)
    }
}
