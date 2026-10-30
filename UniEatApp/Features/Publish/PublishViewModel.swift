import Combine
import Foundation
import UniEatCore

/// borrador de un plato del formulario
/// sale de PublishView aca, ya no es private
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
/// se mueve de PublishView aca y ahora es Equatable para comparar si el formulario cambio
struct PublishDraft: Codable, Sendable, Equatable {
    struct Dish: Codable, Sendable, Equatable {
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

/// todo el estado del formulario de publicar que antes eran @State en PublishView
/// la vista solo dibuja, publicar cerrar y el borrador pasan por PublishingService
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
    // menu que se esta editando, nil si es uno nuevo
    @Published var editingMenu: DailyMenu?
    @Published var message: String?
    @Published var isSaving = false
    @Published private(set) var draftError: String?
    @Published private(set) var draftSavedAt: Date?
    // menus del restaurante, antes estaban en el AppStore viejo
    @Published private(set) var ownMenus: [DailyMenu] = []
    let paymentChoices = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]
    private let service: PublishingService
    private let feed: FeedViewModel
    private let session: SessionStore
    private let connectivity: ConnectivityService
    private var draftTask: Task<Void, Never>?
    private var draftRequest = UUID()
    private let draftSaveDelay: Duration
    let clock: ServerClock
    init(service: PublishingService, feed: FeedViewModel, session: SessionStore,
         connectivity: ConnectivityService, clock: ServerClock, draftSaveDelay: Duration = .milliseconds(400)) {
        self.service = service
        self.feed = feed
        self.session = session
        self.connectivity = connectivity
        self.clock = clock
        self.draftSaveDelay = draftSaveDelay
        super.init()
        observe(session)
        observe(connectivity)
    }
    var approvedEstablishments: [RemoteEstablishment] { session.approvedEstablishments }
    var isOffline: Bool { connectivity.isOffline }
    var canPublishOnline: Bool { !isOffline && session.isAccountVerified }
    /// Agrupa cambios breves: cada tecla cambia estado ligero, no escribe disco en MainActor.
    func scheduleDraftSave() {
        draftTask?.cancel()
        draftSavedAt = nil
        guard editingMenu == nil, hasDraftContent, !isSaving, let userID = session.profile?.id else { return }
        let draft = currentDraft, generation = session.generation, id = UUID(), delay = draftSaveDelay
        draftRequest = id
        draftTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard let self, self.draftRequest == id else { return }
                await self.persistDraft(draft, userID: userID, generation: generation, request: id)
            } catch is CancellationError { }
            catch { /* Task.sleep solo produce cancelación. */ }
        }
    }

    /// Al salir de la pantalla o pasar a segundo plano se guarda la última foto sin esperar el debounce.
    func flushDraft() async {
        draftTask?.cancel()
        guard editingMenu == nil, hasDraftContent, !isSaving, let userID = session.profile?.id else { return }
        let draft = currentDraft, generation = session.generation, id = UUID()
        draftRequest = id
        await persistDraft(draft, userID: userID, generation: generation, request: id)
    }

    private func persistDraft(_ draft: PublishDraft, userID: UUID, generation: UUID, request: UUID) async {
        guard draftRequest == request, session.matches(userID, generation: generation), !Task.isCancelled else { return }
        do {
            try await service.saveDraft(draft, userID: userID, generation: generation)
            guard draftRequest == request, session.matches(userID, generation: generation) else { return }
            draftSavedAt = clock.now
            draftError = nil
        } catch is CancellationError { }
        catch {
            guard draftRequest == request, session.matches(userID, generation: generation) else { return }
            draftError = "No se pudo guardar el borrador en este dispositivo. Conserva el formulario e inténtalo de nuevo."
        }
    }
    /// recupera el borrador de #33 leido en segundo plano
    /// si el usuario escribio algo mientras se leia, no se pisa lo que escribio
    func restoreDraft() async {
        guard editingMenu == nil, let userID = session.profile?.id else { return }
        let expected = currentDraft, generation = session.generation
        do {
            if let draft = try await service.loadDraft(), session.matches(userID, generation: generation),
               editingMenu == nil, currentDraft == expected {
                restore(draft)
            }
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            draftError = "No se pudo leer el borrador guardado. El archivo se conserva para recuperarlo."
        }
    }
    /// al cambiar de cuenta se limpia el formulario para que el siguiente no vea nada
    func reset() {
        draftTask?.cancel()
        draftTask = nil
        draftRequest = UUID()
        draftError = nil
        draftSavedAt = nil
        ownMenus = []
        selectedEstablishmentID = nil
        restaurantName = ""
        area = "Centro"
        address = ""
        entranceDescription = ""
        title = "Almuerzo completo"
        paymentMethods = ["Nequi", "Efectivo"]
        dishes = [DishDraft()]
        editingMenu = nil
        message = nil
        isSaving = false
        validUntil = clock.now.addingTimeInterval(4 * 3600)
    }
    /// pide los menus propios del restaurante
    /// si cambio la sesion mientras tanto se bota la respuesta
    func refresh() async {
        guard let userID = session.profile?.id else { return }
        let generation = session.generation
        do {
            let value = try await service.mine()
            guard session.matches(userID, generation: generation) else { return }
            ownMenus = value
        } catch is CancellationError { return } catch {
            guard session.matches(userID, generation: generation) else { return }
            message = error.localizedDescription
        }
    }
    /// despues de publicar, editar o cerrar: los menus del local y el feed, para ver el cambio de una
    /// al solo entrar a la pestaña no se pide el feed, ya lo tiene la pestaña hoy
    private func refreshAfterChange(userID: UUID, generation: UUID) async {
        guard session.matches(userID, generation: generation) else { return }
        await refresh()
        guard session.matches(userID, generation: generation) else { return }
        feed.invalidateAfterPublicationChange()
        await feed.refresh(force: true)
    }
    /// nombre, titulo, vigencia de maximo 24 horas, local aprobado, pago y platos completos
    var isValid: Bool {
        !restaurantName.trimmingCharacters(in: .whitespaces).isEmpty
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && validUntil > clock.now && validUntil <= clock.now.addingTimeInterval(24 * 60 * 60)
            && selectedEstablishmentID != nil
            && !paymentMethods.isEmpty
            && !dishes.isEmpty && dishes.allSatisfy(\.isComplete)
    }
    /// foto del formulario para guardarla en archivo
    var currentDraft: PublishDraft {
        PublishDraft(establishmentId: selectedEstablishmentID,
                     restaurantName: restaurantName,
                     area: area,
                     address: address,
                     entranceDescription: entranceDescription,
                     title: title,
                     validUntil: validUntil,
                     paymentMethods: paymentChoices.filter(paymentMethods.contains),
                     dishes: dishes.map { PublishDraft.Dish(name: $0.name,
                                                            detail: $0.detail,
                                                            priceText: $0.priceText,
                                                            vegetarian: $0.vegetarian,
                                                            vegan: $0.vegan,
                                                            dietaryKnown: $0.dietaryKnown) })
    }
    /// solo vale la pena guardar si escribio algun plato
    var hasDraftContent: Bool {
        dishes.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || !$0.priceText.isEmpty }
    }
    /// texto de estado de un menu propio con la hora del server
    func statusText(_ menu: DailyMenu) -> String {
        if menu.closedAt != nil { return "cerrada" }
        return menu.isActive(at: clock.now) ? "vigente" : "vencida"
    }
    /// vuelve a llenar el formulario con lo guardado
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
    /// si no hay local elegido se toma el primero aprobado
    func selectFirstEstablishment() {
        guard selectedEstablishmentID == nil, let first = approvedEstablishments.first else { return }
        selectedEstablishmentID = first.id
        fill(from: first)
    }
    /// llena los datos del local en el formulario
    func fill(from establishment: RemoteEstablishment) {
        restaurantName = establishment.name
        area = establishment.area
        address = establishment.address
        entranceDescription = establishment.entranceDescription
        paymentMethods = Set(establishment.paymentMethods)
    }
    /// carga un menu para editarlo, guardar crea una version nueva
    func edit(_ menu: DailyMenu) {
        draftTask?.cancel()
        draftRequest = UUID()
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
    /// cierra el menu antes de que venza, sin red no se intenta
    func close(_ menu: DailyMenu) async {
        guard let userID = session.profile?.id, canPublishOnline else { return }
        let generation = session.generation
        do {
            try await service.close(menu)
            guard session.matches(userID, generation: generation) else { return }
            await refreshAfterChange(userID: userID, generation: generation)
            guard session.matches(userID, generation: generation) else { return }
            if editingMenu?.id == menu.id { editingMenu = nil }
            message = "Publicación cerrada. El historial se conserva."
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            message = (error as? APIFailure)?.message ?? "No se pudo cerrar la publicación. Inténtalo de nuevo."
        }
    }
    /// crea o edita el menu, sin red no se intenta y el borrador se conserva
    /// si otro edito primero el server dice VERSION_CONFLICT y se recarga la version actual
    func publish() async {
        guard isValid, !isSaving, canPublishOnline, let userID = session.profile?.id else { return }
        let generation = session.generation
        draftTask?.cancel()
        draftRequest = UUID()
        isSaving = true
        defer { if session.matches(userID, generation: generation) { isSaving = false } }
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let body = MenuBody(establishmentId: editingMenu?.establishmentId ?? selectedEstablishmentID,
                            title: title, validUntil: validUntil,
                            paymentMethods: paymentChoices.filter(paymentMethods.contains),
                            dishes: dishes.map(\.asBody),
                            establishmentName: restaurantName, area: area,
                            address: trimmedAddress.isEmpty ? nil : trimmedAddress,
                            entranceDescription: entranceDescription,
                            expectedVersion: editingMenu?.version)
        let replacing = editingMenu
        // Si falla la red, el formulario enviado ya tiene una copia durable cuando el disco lo permite.
        if editingMenu == nil, hasDraftContent {
            await persistDraft(currentDraft, userID: userID, generation: generation, request: draftRequest)
        }
        guard session.matches(userID, generation: generation), !Task.isCancelled else { return }
        do {
            try await service.publish(body, replacing: replacing)
            guard session.matches(userID, generation: generation) else { return }
            do {
                try await service.clearDraft(userID: userID, generation: generation)
                draftError = nil
            }
            catch is CancellationError { return }
            catch {
                guard session.matches(userID, generation: generation) else { return }
                draftError = "El menú se publicó, pero no se pudo retirar su borrador local."
            }
            guard session.matches(userID, generation: generation) else { return }
            await refreshAfterChange(userID: userID, generation: generation)
            guard session.matches(userID, generation: generation) else { return }
            dishes = [DishDraft()]
            draftSavedAt = nil
            editingMenu = nil
            message = "Menú publicado. Ya es visible para los estudiantes."
        } catch let failure as APIFailure where failure.code == "VERSION_CONFLICT" {
            guard session.matches(userID, generation: generation) else { return }
            // alguien mas edito primero, se recarga para editar la version actual
            editingMenu = nil
            await refreshAfterChange(userID: userID, generation: generation)
            guard session.matches(userID, generation: generation) else { return }
            message = "Otra persona editó este menú. Recargamos la versión actual; vuelve a aplicar tus cambios."
        } catch is CancellationError { }
        catch {
            guard session.matches(userID, generation: generation) else { return }
            message = (error as? APIFailure)?.message ?? "No se pudo guardar el menú. Revisa los datos e inténtalo de nuevo."
        }
    }
}
