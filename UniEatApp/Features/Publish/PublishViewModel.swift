import Combine
import Foundation
import UniEatCore

struct DishDraft: Identifiable {
    let id = UUID()
    var name = ""
    var detail = ""
    var priceText = ""
    var vegetarian = false
    var vegan = false
    var dietaryKnown = false

    init() {}

    init(dish: MenuDish) {
        name = dish.name
        detail = dish.description
        priceText = String(dish.priceCop)
        vegetarian = dish.dietaryTags.contains("vegetarian")
        vegan = dish.dietaryTags.contains("vegan")
        dietaryKnown = dish.dietaryKnown
    }

    var price: Int { Int(priceText) ?? 0 }
    var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && price > 0 }

    /// la dieta solo se manda si el restaurante la confirmo, vegano tambien cuenta como vegetariano
    var asBody: MenuBody.Dish {
        let tags = vegan ? ["vegetarian", "vegan"] : (vegetarian ? ["vegetarian"] : [])
        return MenuBody.Dish(name: name, description: detail, category: "Almuerzo", priceCop: price,
                             dietaryKnown: dietaryKnown, dietaryTags: dietaryKnown ? tags : [])
    }
}
/// lo que se guarda del formulario en un archivo para no perderlo si se cierra la app o se va la red
struct PublishDraft: Codable {
    struct Dish: Codable {
        var name: String
        var detail: String
        var priceText: String
        var vegetarian: Bool
        var vegan: Bool
        var dietaryKnown: Bool
    }
    var establishmentId: UUID?
    var restaurantName: String
    var area: String
    var address: String
    var entranceDescription: String
    var title: String
    var validUntil: Date
    var paymentMethods: [String]
    var dishes: [Dish]
}


@MainActor
final class PublishViewModel: FeatureViewModel {
    @Published var selectedEstablishmentID: UUID?
    @Published var restaurantName = ""
    @Published var area = "Centro"
    @Published var address = ""
    @Published var entranceDescription = ""
    @Published var title = "Almuerzo completo"
    @Published var validUntil = Date.now.addingTimeInterval(4 * 60 * 60)
    @Published var paymentMethods: Set<String> = ["Nequi", "Efectivo"]
    @Published var dishes = [DishDraft()]
    @Published var editingMenu: DailyMenu?
    @Published var message: String?
    @Published var isSaving = false
    @Published private(set) var ownMenus: [DailyMenu] = []
    let paymentChoices = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]
    private let service: PublishingService
    private let feed: FeedViewModel
    private let session: SessionStore
    private let connectivity: ConnectivityService
    let clock: ServerClock
    init(service: PublishingService, feed: FeedViewModel, session: SessionStore,
         connectivity: ConnectivityService, clock: ServerClock) {
        self.service = service; self.feed = feed; self.session = session
        self.connectivity = connectivity; self.clock = clock
        super.init(); observe(session); observe(connectivity)
    }
    var approvedEstablishments: [RemoteEstablishment] { session.approvedEstablishments }
    var isOffline: Bool { connectivity.isOffline }
    func saveDraft(_ draft: PublishDraft) { service.saveDraft(draft) }
    func loadDraft() -> PublishDraft? { service.loadDraft() }
    func reset() {
        ownMenus = []; selectedEstablishmentID = nil; restaurantName = ""; area = "Centro"
        address = ""; entranceDescription = ""; title = "Almuerzo completo"
        paymentMethods = ["Nequi", "Efectivo"]; dishes = [DishDraft()]; editingMenu = nil
        message = nil; isSaving = false; validUntil = clock.now.addingTimeInterval(4 * 3600)
    }
    func refresh() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation
        do {
            let value = try await service.mine()
            guard session.matches(userID, generation: generation) else { return }
            ownMenus = value
        } catch is CancellationError { } catch { message = error.localizedDescription }
        await feed.refresh()
    }
    var isValid: Bool {
        !restaurantName.trimmingCharacters(in: .whitespaces).isEmpty
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && validUntil > clock.now && validUntil <= clock.now.addingTimeInterval(24 * 60 * 60)
            && selectedEstablishmentID != nil
            && !paymentMethods.isEmpty
            && !dishes.isEmpty && dishes.allSatisfy(\.isComplete)
    }
    var currentDraft: PublishDraft {
        PublishDraft(establishmentId: selectedEstablishmentID,
                     restaurantName: restaurantName,
                     area: area,
                     address: address,
                     entranceDescription: entranceDescription,
                     title: title,
                     validUntil: validUntil,
                     paymentMethods: Array(paymentMethods),
                     dishes: dishes.map { PublishDraft.Dish(name: $0.name,
                                                            detail: $0.detail,
                                                            priceText: $0.priceText,
                                                            vegetarian: $0.vegetarian,
                                                            vegan: $0.vegan,
                                                            dietaryKnown: $0.dietaryKnown) })
    }
    var hasDraftContent: Bool {
        dishes.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || !$0.priceText.isEmpty }
    }
    func statusText(_ menu: DailyMenu) -> String {
        if menu.closedAt != nil { return "cerrada" }
        return menu.isActive(at: clock.now) ? "vigente" : "vencida"
    }
    func restore(_ draft: PublishDraft) {
        selectedEstablishmentID = draft.establishmentId
        restaurantName = draft.restaurantName
        area = draft.area
        address = draft.address
        entranceDescription = draft.entranceDescription
        title = draft.title
        validUntil = draft.validUntil
        paymentMethods = Set(draft.paymentMethods)
        dishes = draft.dishes.map { saved in
            var dish = DishDraft()
            dish.name = saved.name
            dish.detail = saved.detail
            dish.priceText = saved.priceText
            dish.vegetarian = saved.vegetarian
            dish.vegan = saved.vegan
            dish.dietaryKnown = saved.dietaryKnown
            return dish
        }
        message = "Recuperamos tu borrador."
    }
    func selectFirstEstablishment() {
        guard selectedEstablishmentID == nil, let first = approvedEstablishments.first else { return }
        selectedEstablishmentID = first.id
        fill(from: first)
    }
    func fill(from establishment: RemoteEstablishment) {
        restaurantName = establishment.name
        area = establishment.area
        address = establishment.address
        entranceDescription = establishment.entranceDescription
        paymentMethods = Set(establishment.paymentMethods)
    }
    func edit(_ menu: DailyMenu) {
        editingMenu = menu
        selectedEstablishmentID = menu.establishmentId
        restaurantName = menu.establishmentName
        area = menu.area
        address = menu.address
        entranceDescription = menu.entranceDescription
        title = menu.title
        validUntil = max(menu.validUntil, clock.now.addingTimeInterval(60 * 60))
        dishes = menu.items.map(DishDraft.init(dish:))
        paymentMethods = Set(menu.paymentMethods)
        message = "Editando versión \(menu.version). Guardar creará una versión nueva."
    }
    func close(_ menu: DailyMenu) async {
        do {
            try await service.close(menu)
            await refresh()
            if editingMenu?.id == menu.id { editingMenu = nil }
            message = "Publicación cerrada. El historial se conserva."
        } catch {
            message = (error as? APIFailure)?.message ?? "No se pudo cerrar la publicación. Inténtalo de nuevo."
        }
    }
    func publish() async {
        guard isValid, !isOffline else { return }
        isSaving = true
        defer { isSaving = false }
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let body = MenuBody(establishmentId: editingMenu?.establishmentId ?? selectedEstablishmentID,
                            title: title, validUntil: validUntil,
                            paymentMethods: paymentChoices.filter(paymentMethods.contains),
                            dishes: dishes.map(\.asBody),
                            establishmentName: restaurantName, area: area,
                            address: trimmedAddress.isEmpty ? nil : trimmedAddress,
                            entranceDescription: entranceDescription,
                            expectedVersion: editingMenu?.version)
        do {
            try await service.publish(body, replacing: editingMenu)
            service.clearDraft()
            await refresh()
            dishes = [DishDraft()]
            editingMenu = nil
            message = "Menú publicado. Ya es visible para los estudiantes."
        } catch let failure as APIFailure where failure.code == "VERSION_CONFLICT" {
            // alguien mas edito primero, se recarga para editar la version actual
            editingMenu = nil
            await refresh()
            message = "Otra persona editó este menú. Recargamos la versión actual; vuelve a aplicar tus cambios."
        } catch {
            message = (error as? APIFailure)?.message ?? "No se pudo guardar el menú. Revisa los datos e inténtalo de nuevo."
        }
    }
}
