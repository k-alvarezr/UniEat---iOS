import SwiftUI
import UniEatCore

struct PublicationTimingView: View {
    @EnvironmentObject private var store: PublicationTimingViewModel
    @State private var selectedEstablishment: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader(title: "Cuándo publicar")
                if store.isRestaurant {
                    if let error = store.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(Palette.coral)
                        if store.isConnected {
                            Button("Reintentar") { Task { await store.load() } }
                        }
                    }
                    if let snapshot = store.snapshot {
                        timing(snapshot)
                    } else if store.isLoading {
                        ProgressView("Consultando horarios…")
                    } else if !store.isConnected && store.errorMessage == nil {
                        ContentUnavailableView("Sin consulta guardada", systemImage: "wifi.slash",
                                               description: Text("Abre esta pantalla con conexión para guardar la primera copia."))
                    }
                } else {
                    ContentUnavailableView("Solo restaurantes", systemImage: "lock.fill")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Palette.cream)
        .connectionStatus(.publicationTiming)
        .navigationTitle("Cuándo publicar")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.isConnected) { await store.load() }
        .refreshable { await store.load() }
    }

    @ViewBuilder
    private func timing(_ snapshot: PublicationTimingSnapshot) -> some View {
        Text("Aperturas del detalle durante la primera hora · últimos \(snapshot.periodDays) días · hora de Bogotá")
            .font(.subheadline)
        Text("\(store.isShowingCopy ? "Copia del" : "Actualizado el") \(SpanishPresentation.dateAndTime(snapshot.asOf))")
            .font(.caption).foregroundStyle(.secondary)

        let groups = store.groups
        if let group = groups.first(where: { $0.id == selectedEstablishment }) ?? groups.first {
            if groups.count > 1 {
                Picker("Establecimiento", selection: Binding(
                    get: { group.id }, set: { selectedEstablishment = $0 }
                )) {
                    ForEach(groups) { item in Text(item.name).tag(item.id) }
                }
            } else {
                Text(group.name).font(.headline)
            }
            ForEach(group.slots) { slot in slotCard(slot) }
            Text("Se necesitan al menos \(snapshot.minimumSessions) sesiones expuestas en una franja. Las cifras observadas pueden cambiar y sirven para comparar horarios.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ContentUnavailableView("Sin locales en esta consulta", systemImage: "storefront")
        }
    }

    private func slotCard(_ slot: PublicationTimingSlot) -> some View {
        let hours = String(format: "%02d:00–%02d:00", slot.startHour, slot.endHour)
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(hours).font(.headline)
                    Spacer()
                    if let rate = slot.detailOpenRate {
                        Text(rate, format: .percent.precision(.fractionLength(0))).font(.headline)
                    } else {
                        Text("Muestra insuficiente").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let rate = slot.detailOpenRate {
                    ProgressView(value: rate).accessibilityHidden(true)
                }
                Text("Publicaciones: \(slot.publications) · Exposiciones: \(slot.exposedPairs)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
