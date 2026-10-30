import SwiftUI
import UniEatCore

/// filtros de BQ-03, se edita un borrador y solo aplicar cambia el feed
/// sugerir zona usa el gps una vez y lo compara con los pines de los locales
struct FiltersView: View {
    // el borrador de filtros vive en FiltersViewModel, se aplica al feed compartido
    @EnvironmentObject private var model: FiltersViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = LocationContextService()
    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                BrandHeader(title: "Filtros y presupuesto")
                Text("Ajusta tus prioridades")
                    .font(.rounded(25))
                if model.usesCachedCatalog {
                    Text(model.hasSnapshot
                        ? "Aplicaremos los filtros a los datos guardados el \(SpanishPresentation.dateAndTime(model.fetchedAt)). La disponibilidad se comprobará al recuperar conexión."
                        : "Puedes ajustar tus filtros. Descarga los menús al recuperar conexión para aplicarlos a una copia local.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Presupuesto por plato", icon: "banknote")
                        Text((model.draft.budgetCop ?? 20_000).cop)
                            .font(.rounded(25, .black))
                        Slider(value: Binding(get: { Double(model.draft.budgetCop ?? 20_000) },
                                              set: { model.draft.budgetCop = Int($0) }),
                               in: 5_000...40_000, step: 1_000)
                            .tint(Palette.yellow)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Tiempo disponible", icon: "clock")
                        Picker("Tiempo", selection: Binding(get: { model.draft.availableMinutes ?? 40 },
                                                          set: { model.draft.availableMinutes = $0 })) {
                            ForEach([15, 30, 45, 60], id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Preferencia dietaria", icon: "leaf")
                        HStack {
                            choice("Todas", value: nil, selected: $model.draft.diet)
                            choice("Vegetariana", value: "vegetarian", selected: $model.draft.diet)
                            choice("Vegana", value: "vegan", selected: $model.draft.diet)
                        }
                        Text("La dieta desconocida nunca se presenta como confirmada.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Zona del campus", icon: "mappin")
                        Picker("Zona", selection: Binding(get: { model.draft.area ?? "Centro" },
                                                       set: { model.draft.area = $0; model.locationMessage = nil })) {
                            ForEach(areas, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Button {
                            model.locationMessage = nil
                            location.request()
                        } label: {
                            Label("Sugerir zona con mi ubicación", systemImage: "location")
                        }
                        .buttonStyle(.bordered)
                        if let message = model.locationMessage ?? location.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Se consulta el GPS una vez y se compara con los pines publicados. Tu ubicación no se envía ni se guarda.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Medio de pago", icon: "creditcard")
                        Picker("Pago", selection: Binding(get: { model.draft.paymentMethod ?? "Todos" },
                                                       set: { model.draft.paymentMethod = $0 == "Todos" ? nil : $0 })) {
                            ForEach(["Todos", "Nequi", "Daviplata", "Efectivo", "Tarjeta"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                Button("Restablecer") { model.draft = FeedFilters() }
                    .font(.subheadline.weight(.bold))
                    .padding(.vertical, 8)
                SolidButton(title: "Aplicar filtros", icon: "arrow.right", color: Palette.coral) {
                    model.apply()
                    dismiss()
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .onAppear { model.reset() }
        .onReceive(location.$location) { position in model.suggest(position) }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.rounded(16))
    }

    private func choice(_ title: String, value: String?, selected: Binding<String?>) -> some View {
        Button(title) { selected.wrappedValue = value }
            .font(.rounded(12, .bold))
            .padding(.horizontal, 9).padding(.vertical, 9)
            .background(selected.wrappedValue == value ? Palette.yellow : Palette.cream,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.ink, lineWidth: 1.5))
            .foregroundStyle(Palette.ink)
    }
}
