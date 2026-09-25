import SwiftUI

@main
struct UniEatApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environment(\.locale, SpanishPresentation.locale)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.profile == nil {
                AuthView()
            } else {
                MainTabsView()
            }
        }
        .tint(Palette.ink)
    }
}
