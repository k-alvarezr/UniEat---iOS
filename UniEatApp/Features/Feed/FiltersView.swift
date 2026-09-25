import SwiftUI
import UniEatCore

struct FiltersView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = FeedFilters()
    private let areas = ["Centro", "Norte", "Sur", "Fuera del campus"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                BrandHeader(title: "Filtros y presupuesto")
                Text("Ajusta tus prioridades")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Presupuesto por plato", icon: "banknote")
                        Text((draft.budgetCop ?? 20_000).cop)
                            .font(.system(size: 25, weight: .black, design: .rounded))
                        Slider(value: Binding(get: { Double(draft.budgetCop ?? 20_000) },
                                              set: { draft.budgetCop = Int($0) }),
                               in: 5_000...40_000, step: 1_000)
                            .tint(Palette.yellow)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Tiempo disponible", icon: "clock")
                        Picker("Tiempo", selection: Binding(get: { draft.availableMinutes ?? 40 },
                                                          set: { draft.availableMinutes = $0 })) {
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
                            choice("Todas", value: nil, selected: $draft.diet)
                            choice("Vegetariana", value: "vegetarian", selected: $draft.diet)
                            choice("Vegana", value: "vegan", selected: $draft.diet)
                        }
                        Text("La dieta desconocida nunca se presenta como confirmada.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Zona del campus", icon: "mappin")
                        Picker("Zona", selection: Binding(get: { draft.area ?? "Centro" },
                                                       set: { draft.area = $0 })) {
                            ForEach(areas, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Medio de pago", icon: "creditcard")
                        Picker("Pago", selection: Binding(get: { draft.paymentMethod ?? "Todos" },
                                                       set: { draft.paymentMethod = $0 == "Todos" ? nil : $0 })) {
                            ForEach(["Todos", "Nequi", "Daviplata", "Efectivo", "Tarjeta"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                Button("Restablecer") { draft = FeedFilters() }
                    .font(.subheadline.weight(.bold))
                    .padding(.vertical, 8)
                SolidButton(title: "Aplicar filtros", icon: "arrow.right", color: Palette.coral) {
                    store.updateFilters(draft)
                    dismiss()
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .onAppear { draft = store.filters }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 16, weight: .heavy, design: .rounded))
    }

    private func choice(_ title: String, value: String?, selected: Binding<String?>) -> some View {
        Button(title) { selected.wrappedValue = value }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 9)
            .background(selected.wrappedValue == value ? Palette.yellow : Palette.cream,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.ink, lineWidth: 1.5))
            .foregroundStyle(Palette.ink)
    }
}
