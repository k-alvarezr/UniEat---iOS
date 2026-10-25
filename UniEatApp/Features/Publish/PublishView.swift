import SwiftUI
import UniEatCore

/// borrador de un plato del formulario
private struct DishDraft: Identifiable {
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

/// pestaña publicar para restaurantes, crear editar y cerrar el menu del dia
struct PublishView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedEstablishmentID: UUID?
    @State private var restaurantName = ""
    @State private var area = "Centro"
    @State private var address = ""
    @State private var entranceDescription = ""
    @State private var title = "Almuerzo completo"
    @State private var validUntil = Date.now.addingTimeInterval(4 * 60 * 60)
    @State private var paymentMethods: Set<String> = ["Nequi", "Efectivo"]
    @State private var dishes = [DishDraft()]
    @State private var editingMenu: DailyMenu?
    @State private var message: String?
    @State private var isSaving = false

    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]
    private let paymentChoices = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]

    private var isValid: Bool {
        !restaurantName.trimmingCharacters(in: .whitespaces).isEmpty
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && validUntil > .now && validUntil <= .now.addingTimeInterval(24 * 60 * 60)
            && selectedEstablishmentID != nil
            && !paymentMethods.isEmpty
            && !dishes.isEmpty && dishes.allSatisfy(\.isComplete)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                BrandHeader(title: "UniEat · Publicar")
                Text(editingMenu == nil ? "Publicar menú del día" : "Editar menú del día").font(.rounded(27))
                Text("Completa los campos estructurados para que estudiantes puedan comparar y filtrar tu oferta.")
                    .font(.subheadline).foregroundStyle(.secondary)
                establishmentSection
                menuSection
                ForEach($dishes) { $dish in dishCard($dish) }
                if dishes.count < 12 {
                    Button { dishes.append(DishDraft()) } label: {
                        Label("Agregar otro plato", systemImage: "plus.circle").frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .font(.headline)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(Palette.ink)
                        .padding(12)
                        .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 12))
                }
                SolidButton(title: isSaving ? "Guardando…" : (editingMenu == nil ? "Publicar menú ahora" : "Guardar cambios"),
                            icon: "arrow.right", color: Palette.coral) {
                    Task { await publish() }
                }
                .disabled(!isValid || isSaving)
                myMenus
            }
            .padding(16)
        }
        .background(Palette.cream)
        .onAppear(perform: selectFirstEstablishment)
        .onChange(of: store.approvedEstablishments.map(\.id)) { _, _ in selectFirstEstablishment() }
    }

    // MARK: - partes del formulario

    private var establishmentSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Tu establecimiento")
                if store.approvedEstablishments.isEmpty {
                    Text("No tienes establecimientos aprobados. Solicita uno o actualiza su estado en Perfil.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("Local que publica", selection: $selectedEstablishmentID) {
                        Text("Selecciona un local").tag(UUID?.none)
                        ForEach(store.approvedEstablishments) { establishment in
                            Text(establishment.name).tag(Optional(establishment.id))
                        }
                    }
                    .disabled(editingMenu != nil)
                    .onChange(of: selectedEstablishmentID) { _, selected in
                        guard editingMenu == nil,
                              let establishment = store.approvedEstablishments.first(where: { $0.id == selected }) else { return }
                        fill(from: establishment)
                    }
                }
                TextField("Nombre del restaurante", text: $restaurantName).textFieldStyle(.roundedBorder)
                Picker("Área", selection: $area) {
                    ForEach(areas, id: \.self) { Text($0).tag($0) }
                }
                TextField("Dirección o referencia de entrada", text: $address).textFieldStyle(.roundedBorder)
                TextField("Cómo encontrar la entrada (opcional)", text: $entranceDescription).textFieldStyle(.roundedBorder)
                Text("Medios de pago aceptados").font(.subheadline.weight(.bold))
                ForEach(paymentChoices, id: \.self) { method in
                    Toggle(method, isOn: Binding(
                        get: { paymentMethods.contains(method) },
                        set: { isOn in
                            if isOn { paymentMethods.insert(method) } else { paymentMethods.remove(method) }
                        }
                    ))
                }
            }
        }
    }

    private var menuSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Menú de hoy")
                TextField("Nombre del menú", text: $title).textFieldStyle(.roundedBorder)
                DatePicker("Válido hasta", selection: $validUntil, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                Text("La publicación dejará de aparecer al vencer. La vigencia máxima es de 24 horas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dishCard(_ dish: Binding<DishDraft>) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("Plato")
                    Spacer()
                    if dishes.count > 1 {
                        Button(role: .destructive) {
                            dishes.removeAll { $0.id == dish.wrappedValue.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                TextField("Nombre del plato", text: dish.name).textFieldStyle(.roundedBorder)
                TextField("Descripción opcional", text: dish.detail).textFieldStyle(.roundedBorder)
                TextField("Precio en COP", text: dish.priceText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Toggle("Información dietaria confirmada", isOn: dish.dietaryKnown)
                if dish.wrappedValue.dietaryKnown {
                    Toggle("Vegetariano", isOn: dish.vegetarian)
                    Toggle("Vegano", isOn: dish.vegan)
                }
            }
        }
    }

    @ViewBuilder private var myMenus: some View {
        if store.ownMenus.isEmpty {
            SurfaceCard {
                Label("Aún no has publicado un menú del día.", systemImage: "storefront").font(.subheadline)
            }
        } else {
            Text("Mis publicaciones").font(.rounded(21))
            ForEach(store.ownMenus) { menu in
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(menu.title).font(.headline)
                        Text("Versión \(menu.version) · \(statusText(menu))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if menu.closedAt == nil {
                                Button("Editar") { edit(menu) }.buttonStyle(.bordered)
                            }
                            if menu.isActive() {
                                Button("Cerrar publicación", role: .destructive) { Task { await close(menu) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.rounded(17))
    }

    private func statusText(_ menu: DailyMenu) -> String {
        if menu.closedAt != nil { return "cerrada" }
        return menu.isActive() ? "vigente" : "vencida"
    }

    // MARK: - acciones

    private func selectFirstEstablishment() {
        guard selectedEstablishmentID == nil, let first = store.approvedEstablishments.first else { return }
        selectedEstablishmentID = first.id
        fill(from: first)
    }

    private func fill(from establishment: RemoteEstablishment) {
        restaurantName = establishment.name
        area = establishment.area
        address = establishment.address
        entranceDescription = establishment.entranceDescription
        paymentMethods = Set(establishment.paymentMethods)
    }

    private func edit(_ menu: DailyMenu) {
        editingMenu = menu
        selectedEstablishmentID = menu.establishmentId
        restaurantName = menu.establishmentName
        area = menu.area
        address = menu.address
        entranceDescription = menu.entranceDescription
        title = menu.title
        validUntil = max(menu.validUntil, Date.now.addingTimeInterval(60 * 60))
        dishes = menu.items.map(DishDraft.init(dish:))
        paymentMethods = Set(menu.paymentMethods)
        message = "Editando versión \(menu.version). Guardar creará una versión nueva."
    }

    private func close(_ menu: DailyMenu) async {
        do {
            try await store.close(menu)
            if editingMenu?.id == menu.id { editingMenu = nil }
            message = "Publicación cerrada. El historial se conserva."
        } catch {
            message = (error as? APIFailure)?.message ?? "No se pudo cerrar la publicación. Inténtalo de nuevo."
        }
    }

    private func publish() async {
        guard isValid else { return }
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
            try await store.publish(body, replacing: editingMenu)
            dishes = [DishDraft()]
            editingMenu = nil
            message = "Menú publicado. Ya es visible para los estudiantes."
        } catch let failure as APIFailure where failure.code == "VERSION_CONFLICT" {
            // alguien mas edito primero, se recarga para editar la version actual
            editingMenu = nil
            await store.refresh()
            message = "Otra persona editó este menú. Recargamos la versión actual; vuelve a aplicar tus cambios."
        } catch {
            message = (error as? APIFailure)?.message ?? "No se pudo guardar el menú. Revisa los datos e inténtalo de nuevo."
        }
    }
}
