import MapKit
import SwiftUI
import UniEatCore

struct MenuDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingReport = false
    let menu: Menu

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BrandHeader(title: "Detalle del plato")
                DemoNotice()
                FoodArtwork(name: menu.establishmentName)
                    .frame(height: 180)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(menu.establishmentName)
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                        Text(menu.title).font(.subheadline)
                    }
                    Spacer()
                    Sticker(text: "Desde \(menu.lowestPriceCop.cop)", color: Palette.yellow)
                }
                HStack(spacing: 8) {
                    Sticker(text: menu.area, color: Palette.cyan, icon: "mappin")
                    Sticker(text: menu.isActive(at: timeline.date) ? "Vigente" : "Vencido",
                            color: menu.isActive(at: timeline.date) ? Palette.green : Palette.coral,
                            icon: menu.isActive(at: timeline.date) ? "checkmark.circle" : "clock.badge.exclamationmark")
                    if store.pendingReports(for: menu) > 0 {
                        Sticker(text: "Reporte pendiente", color: Palette.coral, icon: "exclamationmark.circle")
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Información de espera", systemImage: "clock")
                            .font(.headline)
                        if menu.hasWaitEvidence(at: timeline.date), let wait = menu.waitMinutes {
                            Text("~\(wait) minutos")
                                .font(.system(size: 30, weight: .black, design: .rounded))
                            Text("Estimación basada en \(menu.waitSampleCount) reportes recientes. No es un tiempo garantizado.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let updated = menu.waitNewestReportAt {
                                Text("Último reporte: \(updated.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                            }
                        } else {
                            InsufficientEvidenceView(count: menu.waitSampleCount)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Menú del día")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                    ForEach(menu.items) { dish in
                        SurfaceCard {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(dish.name).font(.system(size: 16, weight: .bold, design: .rounded))
                                    if !dish.description.isEmpty {
                                        Text(dish.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(dish.dietaryKnown ? (dish.dietaryTags.isEmpty ? "Dieta declarada" : dish.dietaryTags.joined(separator: ", ")) : "Dieta sin confirmar")
                                        .font(.caption)
                                }
                                Spacer()
                                Sticker(text: dish.priceCop.cop, color: Palette.yellow)
                            }
                        }
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Ubicación exacta", systemImage: "map")
                            .font(.headline)
                        if let latitude = menu.latitude, let longitude = menu.longitude {
                            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                          span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))) {
                                Marker(menu.establishmentName, coordinate: coordinate)
                            }
                            .frame(height: 175)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            if let mapURL = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") {
                                Link("Abrir indicaciones", destination: mapURL)
                                    .font(.subheadline.weight(.bold))
                            }
                        } else {
                            Text("Ubicación no confirmada").font(.subheadline)
                        }
                        Text(menu.address.isEmpty ? "Dirección no publicada" : menu.address)
                        if !menu.entranceDescription.isEmpty { Text(menu.entranceDescription).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Medios de pago").font(.headline)
                        Text(menu.paymentMethods.isEmpty ? "Sin información declarada" : menu.paymentMethods.joined(separator: " · "))
                        Text("Válido hasta \(menu.validUntil.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if menu.isActive(at: timeline.date) {
                    SolidButton(title: "Elegir este menú", icon: "checkmark", color: Palette.yellow) {
                        store.track("selection", menu: menu)
                    }
                } else {
                    Text("Esta publicación venció. Vuelve al feed para ver opciones vigentes.")
                        .font(.subheadline.weight(.bold))
                        .padding(12)
                        .background(Palette.coral.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
                SolidButton(title: "Reportar un cambio", icon: "exclamationmark.bubble", color: Palette.coral) {
                    showingReport = true
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReport) { ReportSheet(menu: menu) }
        .onAppear { store.track("detail_open", menu: menu) }
        }
    }
}

struct InsufficientEvidenceView: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Información insuficiente", systemImage: "hourglass")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            Text("Hay \(count) reporte(s) reciente(s). Se necesitan al menos tres para mostrar una estimación.")
                .font(.subheadline)
            Text("Puedes informar el tiempo de fila después de visitar el local.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
    }
}
