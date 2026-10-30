import SwiftUI
import UniEatCore

/// borrador de un plato del formulario

/// pestaña publicar para restaurantes, crear editar y cerrar el menu del dia
struct PublishView: View {
    // el formulario ahora vive en PublishViewModel, aca solo se dibuja
    @EnvironmentObject private var model: PublishViewModel
    @Environment(\.scenePhase) private var scenePhase

    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]
    private let paymentChoices = ["Nequi", "Daviplata", "Efectivo", "Tarjeta"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                BrandHeader(title: "UniEat · Publicar")
                Text(model.editingMenu == nil ? "Publicar menú del día" : "Editar menú del día").font(.rounded(27))
                Text("Completa los campos estructurados para que estudiantes puedan comparar y filtrar tu oferta.")
                    .font(.subheadline).foregroundStyle(.secondary)
                establishmentSection
                menuSection
                ForEach($model.dishes) { $dish in dishCard($dish) }
                if model.dishes.count < 12 {
                    Button { model.dishes.append(DishDraft()) } label: {
                        Label("Agregar otro plato", systemImage: "plus.circle").frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .font(.headline)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = model.message {
                    Text(message).font(.subheadline).foregroundStyle(Palette.ink)
                        .padding(12)
                        .background(Palette.cyan, in: RoundedRectangle(cornerRadius: 12))
                }
                if let error = model.draftError {
                    Text(error).font(.footnote).foregroundStyle(Palette.coral)
                    Button("Reintentar guardar borrador") { Task { await model.flushDraft() } }
                } else if model.draftSavedAt != nil, model.editingMenu == nil, model.hasDraftContent {
                    Label("Borrador guardado en este dispositivo", systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SolidButton(title: model.isSaving ? "Guardando…" : (model.editingMenu == nil ? "Publicar menú ahora" : "Guardar cambios"),
                            icon: "arrow.right", color: Palette.coral) {
                    Task { await model.publish() }
                }
                .disabled(!model.isValid || model.isSaving || !model.canPublishOnline)
                myMenus
            }
            .padding(16)
        }
        .disabled(model.isSaving)
        .background(Palette.cream)
        .connectionStatus(.publishing)
        .task {
            await model.restoreDraft()
            model.selectFirstEstablishment()
            await model.refresh()
        }
        .onAppear(perform: model.selectFirstEstablishment)
        .onChange(of: model.approvedEstablishments.map(\.id)) { _, _ in model.selectFirstEstablishment() }
        .onChange(of: model.canPublishOnline) { _, available in
            if available { Task { await model.refresh() } }
        }
        .onChange(of: model.currentDraft) { _, _ in model.scheduleDraftSave() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flushDraft() } }
        }
        .onDisappear { Task { await model.flushDraft() } }

    }

    // MARK: - partes del formulario

    private var establishmentSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Tu establecimiento")
                if model.approvedEstablishments.isEmpty {
                    Text("No tienes establecimientos aprobados. Solicita uno o actualiza su estado en Perfil.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("Local que publica", selection: $model.selectedEstablishmentID) {
                        Text("Selecciona un local").tag(UUID?.none)
                        ForEach(model.approvedEstablishments) { establishment in
                            Text(establishment.name).tag(Optional(establishment.id))
                        }
                    }
                    .disabled(model.editingMenu != nil)
                    .onChange(of: model.selectedEstablishmentID) { _, selected in
                        guard model.editingMenu == nil,
                              let establishment = model.approvedEstablishments.first(where: { $0.id == selected }) else { return }
                        model.fill(from: establishment)
                    }
                }
                TextField("Nombre del restaurante", text: $model.restaurantName).textFieldStyle(.roundedBorder)
                Picker("Área", selection: $model.area) {
                    ForEach(areas, id: \.self) { Text($0).tag($0) }
                }
                TextField("Dirección o referencia de entrada", text: $model.address).textFieldStyle(.roundedBorder)
                TextField("Cómo encontrar la entrada (opcional)", text: $model.entranceDescription).textFieldStyle(.roundedBorder)
                Text("Medios de pago aceptados").font(.subheadline.weight(.bold))
                ForEach(paymentChoices, id: \.self) { method in
                    Toggle(method, isOn: Binding(
                        get: { model.paymentMethods.contains(method) },
                        set: { isOn in
                            if isOn { model.paymentMethods.insert(method) } else { model.paymentMethods.remove(method) }
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
                TextField("Nombre del menú", text: $model.title).textFieldStyle(.roundedBorder)
                DatePicker("Válido hasta", selection: $model.validUntil, in: model.clock.now..., displayedComponents: [.date, .hourAndMinute])
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
                    if model.dishes.count > 1 {
                        Button(role: .destructive) {
                            model.dishes.removeAll { $0.id == dish.wrappedValue.id }
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
        HStack {
            Text("Mis publicaciones").font(.rounded(21))
            Spacer()
            Button(model.isRefreshingOwnMenus ? "Actualizando…" : "Actualizar") { Task { await model.refresh() } }
                .disabled(!model.canPublishOnline || model.isRefreshingOwnMenus)
        }
        if !model.hasLoadedOwnMenus {
            Text("Aún no hay una lista descargada de tus publicaciones. Puedes trabajar en el borrador y actualizar la lista al recuperar el servicio.")
                .font(.footnote).foregroundStyle(.secondary)
        } else if model.ownMenus.isEmpty {
            SurfaceCard {
                Label("Aún no has publicado un menú del día.", systemImage: "storefront").font(.subheadline)
            }
        } else {
            ForEach(model.ownMenus) { menu in
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(menu.title).font(.headline)
                        Text("Versión \(menu.version) · \(model.statusText(menu))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if menu.closedAt == nil {
                                Button("Editar") { model.edit(menu) }.buttonStyle(.bordered)
                            }
                            if menu.isActive() {
                                Button("Cerrar publicación", role: .destructive) { Task { await model.close(menu) } }
                                    .disabled(!model.canPublishOnline || model.isSaving)
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

    // MARK: - acciones
    
    // foto del formulario para guardarla en archivo

    // solo vale la pena guardar si escribio algun plato

    // vuelve a llenar el formulario con lo guardado

}
