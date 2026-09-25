import Foundation
import Network
import SwiftUI
import UniEatCore

struct InteractionEvent: Codable, Identifiable {
    let id: UUID
    let menuID: UUID
    let kind: String
    let date: Date

    init(menuID: UUID, kind: String) {
        id = UUID()
        self.menuID = menuID
        self.kind = kind
        date = .now
    }
}

struct SubmittedReport: Codable, Identifiable {
    let id: UUID
    let menuID: UUID
    let menuVersion: Int
    let kind: ReportKind
    let note: String
    let waitMinutes: Int?
    let date: Date

    init(menu: Menu, kind: ReportKind, note: String, waitMinutes: Int?) {
        id = UUID()
        menuID = menu.id
        menuVersion = menu.version
        self.kind = kind
        self.note = note
        self.waitMinutes = waitMinutes
        date = .now
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var menus: [Menu] = SampleMenus.all
    @Published private(set) var filters: FeedFilters = FeedFilters()
    @Published private(set) var isConnected = true
    @Published var forceOffline = false
    @Published private(set) var cachedAt = Date.now
    @Published private(set) var reports: [SubmittedReport] = []
    @Published private(set) var events: [InteractionEvent] = []
    @Published var authMessage: String?

    let configuration = AppConfiguration.current
    private let repository: MenuRepository = DemoMenuRepository()
    private let ranking: FeedRankingStrategy = ContextualRankingStrategy()
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "unieat.connectivity")
    private let auth = SupabaseAuthService()
    private var impressions: Set<UUID> = []
    private let demoStudentID = UUID(uuidString: "FEED0000-0000-4000-8000-000000000001")!
    private let demoRestaurantID = UUID(uuidString: "FEED0000-0000-4000-8000-000000000002")!

    init() {
        if let data = UserDefaults.standard.data(forKey: "unieat.filters"),
           let saved = try? JSONDecoder().decode(FeedFilters.self, from: data) {
            filters = saved
        }
        if let data = UserDefaults.standard.data(forKey: "unieat.demo.reports.v1"),
           let saved = try? UniEatDates.decoder().decode([SubmittedReport].self, from: data) {
            reports = saved
        }
        if let data = UserDefaults.standard.data(forKey: "unieat.demo.events.v1"),
           let saved = try? UniEatDates.decoder().decode([InteractionEvent].self, from: data) {
            events = saved
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.isConnected = path.status == .satisfied }
        }
        monitor.start(queue: monitorQueue)
        Task {
            await refresh()
            if let restored = await auth.restore() { profile = restored }
        }
    }

    var isOffline: Bool { forceOffline || !isConnected }
    var isRestaurant: Bool { profile?.role == "restaurant" }
    var rankedMenus: [Menu] { ranking.ranked(menus, for: filters, at: .now) }
    var topRecommendation: Menu? { rankedMenus.first }
    func explanation(for menu: Menu) -> String {
        ranking.explanation(for: menu, filters: filters, at: .now)
    }
    var ownMenus: [Menu] {
        guard let id = profile?.id else { return [] }
        return menus.filter { $0.establishmentId == id }
    }

    func refresh() async {
        do {
            menus = try await repository.loadMenus()
            cachedAt = .now
        } catch {
            authMessage = "No se pudo abrir la copia local de los menús."
        }
    }

    func updateFilters(_ value: FeedFilters) {
        filters = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "unieat.filters")
        }
        trackGlobal("filter_apply")
    }

    func enterDemo(role: String) {
        profile = Profile(id: role == "restaurant" ? demoRestaurantID : demoStudentID,
                          displayName: role == "restaurant" ? "Mi restaurante" : "Estudiante Uniandes", role: role)
        authMessage = nil
    }

    func signIn(email: String, password: String) async throws {
        profile = try await auth.signIn(email: email, password: password)
        authMessage = nil
    }

    func signUp(email: String, password: String, name: String, role: String) async throws {
        if let signedIn = try await auth.signUp(email: email, password: password, name: name, role: role) {
            profile = signedIn
            authMessage = nil
        } else {
            authMessage = "Revisa tu correo para confirmar la cuenta y luego inicia sesión."
        }
    }

    func signOut() {
        auth.signOut()
        profile = nil
        impressions.removeAll()
    }

    func track(_ kind: String, menu: Menu) {
        if kind == "feed_impression" && !impressions.insert(menu.id).inserted { return }
        events.append(InteractionEvent(menuID: menu.id, kind: kind))
        persistEvents()
    }

    private func trackGlobal(_ kind: String) {
        events.append(InteractionEvent(menuID: UUID(), kind: kind))
        persistEvents()
    }

    private func persistEvents() {
        if let data = try? UniEatDates.encoder().encode(events) {
            UserDefaults.standard.set(data, forKey: "unieat.demo.events.v1")
        }
    }

    func pendingReports(for menu: Menu) -> Int {
        menu.pendingReports + reports.filter { $0.menuID == menu.id && $0.menuVersion == menu.version }.count
    }

    func submitReport(for menu: Menu, kind: ReportKind, note: String, waitMinutes: Int?) {
        reports.append(SubmittedReport(menu: menu, kind: kind, note: note, waitMinutes: waitMinutes))
        if let data = try? UniEatDates.encoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: "unieat.demo.reports.v1")
        }
        if kind == .arrival { track("arrival", menu: menu) }
        // The demo keeps reports on this device. A future remote repository sends
        // publication id, version and authenticated author to the shared backend.
    }

    func publish(title: String, restaurantName: String, area: String, address: String,
                 validUntil: Date, dishes: [MenuDish]) async throws {
        guard let owner = profile, owner.role == "restaurant" else { return }
        let menu = Menu(title: title, validUntil: validUntil, establishmentId: owner.id,
                        establishmentName: restaurantName, area: area, address: address,
                        paymentMethods: ["Nequi", "Efectivo"], items: dishes,
                        lowestPriceCop: dishes.map(\.priceCop).min() ?? 0,
                        explanation: "Publicado por este restaurante")
        try await repository.saveMenu(menu)
        await refresh()
    }

    func performance(days: Int) -> PerformanceSummary {
        let ownIDs = Set(ownMenus.map(\.id))
        let recent = events.filter { ownIDs.contains($0.menuID) && $0.date >= .now.addingTimeInterval(Double(-days * 86_400)) }
        return PerformanceSummary(periodDays: days,
                                  impressions: recent.filter { $0.kind == "feed_impression" }.count,
                                  detailOpens: recent.filter { $0.kind == "detail_open" }.count,
                                  selections: recent.filter { $0.kind == "selection" }.count,
                                  reportedArrivals: recent.filter { $0.kind == "arrival" }.count)
    }
}
