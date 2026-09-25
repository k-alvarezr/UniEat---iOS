import SwiftUI
import UniEatCore

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
}

struct PublishView: View {
    @EnvironmentObject private var store: AppStore
    @State private var restaurantName = ""
    @State private var area = "Centro"
    @State private var address = ""
    @State private var title = "Almuerzo completo"
    @State private var validUntil = Date.now.addingTimeInterval(4 * 60 * 60)
    @State private var dishes = [DishDraft()]
    @State private var isSaving = false
    @State private var message: String?
    @State private var editingMenu: Menu?

    private var valid: Bool {
        !restaurantName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        validUntil > .now && !dishes.isEmpty &&
        dishes.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            (Int($0.priceText) ?? 0) > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                BrandHeader(title: "UniEat · Publicar")
                DemoNotice()
                Text(editingMenu == nil ? "Publicar menú del día" : "Editar menú del día")
                    .font(.system(size: 27, weight: .heavy, design: .rounded))
                Text("Completa los campos estructurados para que estudiantes puedan comparar y filtrar tu oferta.")
                    .font(.subheadline).foregroundStyle(.secondary)
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        section("Tu establecimiento")
                        TextField("Nombre del restaurante", text: $restaurantName)
                            .textFieldStyle(.roundedBorder)
                        Picker("Área", selection: $area) {
                            ForEach(["Centro", "Norte", "Sur", "Fuera del campus"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        TextField("Dirección o referencia de entrada", text: $address)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        section("Menú de hoy")
                        TextField("Nombre del menú", text: $title)
                            .textFieldStyle(.roundedBorder)
                        DatePicker("Válido hasta", selection: $validUntil, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        Text("La publicación dejará de aparecer al vencer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach($dishes) { $dish in
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                section("Plato")
                                Spacer()
                                if dishes.count > 1 {
                                    Button(role: .destructive) { dishes.removeAll { $0.id == dish.id } } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                            TextField("Nombre del plato", text: $dish.name)
                                .textFieldStyle(.roundedBorder)
                            TextField("Descripción opcional", text: $dish.detail)
                                .textFieldStyle(.roundedBorder)
                            TextField("Precio en COP", text: $dish.priceText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Información dietaria confirmada", isOn: $dish.dietaryKnown)
                            if dish.dietaryKnown {
                                Toggle("Vegetariano", isOn: $dish.vegetarian)
                                Toggle("Vegano", isOn: $dish.vegan)
                            }
                        }
                    }
                }
                if dishes.count < 12 {
                    Button { dishes.append(DishDraft()) } label: {
                        Label("Agregar otro plato", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 48)
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
                .disabled(!valid || isSaving)
                if store.ownMenus.isEmpty {
                    SurfaceCard {
                        Label("Aún no has publicado un menú del día.", systemImage: "storefront")
                            .font(.subheadline)
                    }
                } else {
                    Text("Mis publicaciones")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                    ForEach(store.ownMenus) { menu in
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(menu.title).font(.headline)
                                Text("Versión \(menu.version) · \(menu.isActive() ? "vigente" : "cerrada o vencida")")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Editar") { edit(menu) }
                                        .buttonStyle(.bordered)
                                    if menu.isActive() {
                                        Button("Cerrar publicación", role: .destructive) {
                                            Task { await close(menu) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .onAppear {
            if restaurantName.isEmpty { restaurantName = store.profile?.displayName ?? "" }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 17, weight: .heavy, design: .rounded))
    }

    private func edit(_ menu: Menu) {
        editingMenu = menu
        restaurantName = menu.establishmentName
        area = menu.area
        address = menu.address
        title = menu.title
        validUntil = max(menu.validUntil, Date.now.addingTimeInterval(60 * 60))
        dishes = menu.items.map(DishDraft.init(dish:))
        message = "Editando versión \(menu.version). Guardar creará una versión nueva."
    }

    private func close(_ menu: Menu) async {
        do {
            try await store.close(menu)
            if editingMenu?.id == menu.id { editingMenu = nil }
            message = "Publicación cerrada en este dispositivo."
        } catch {
            message = error.localizedDescription
        }
    }

    private func publish() async {
        guard valid else { return }
        isSaving = true
        defer { isSaving = false }
        let items = dishes.map { draft in
            MenuDish(name: draft.name, description: draft.detail, priceCop: Int(draft.priceText) ?? 0,
                     dietaryTags: draft.vegan ? ["vegetarian", "vegan"] : (draft.vegetarian ? ["vegetarian"] : []),
                     dietaryKnown: draft.dietaryKnown)
        }
        do {
            try await store.publish(title: title, restaurantName: restaurantName, area: area,
                                    address: address, validUntil: validUntil, dishes: items,
                                    replacing: editingMenu)
            dishes = [DishDraft()]
            editingMenu = nil
            message = "Menú guardado en este dispositivo (demo)."
        } catch {
            message = error.localizedDescription
        }
    }
}
