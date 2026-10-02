import MapKit
import SwiftUI
import UniEatCore

struct MenuDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingReport = false
    /// Copia que llegó del feed; se muestra mientras llega la versión del servidor.
    private let initialMenu: DailyMenu
    @State private var detail: MenuDetail?
    @State private var loadError: APIFailure?
    @State private var isLoading = false

    init(menu: DailyMenu) { initialMenu = menu }

    /// Lo que la vista muestra: la versión del servidor si ya llegó; si no, la copia del feed.
    private var menu: DailyMenu { detail?.menu ?? initialMenu }
    /// 410 (vencido o cerrado) o 404: la publicación ya no admite elegir ni reportar.
    private var isGone: Bool { ["GONE", "NOT_FOUND"].contains(loadError?.code ?? "") }

    private func isOpen(at date: Date) -> Bool {
        if isGone { return false }
        if let detail { return detail.status(at: date).acceptsActions }
        return menu.isActive(at: date)
    }

    private func statusLabel(at date: Date) -> String {
        if isGone { return "No disponible" }
        if let detail { return detail.status(at: date).label }
        return menu.isActive(at: date) ? "Vigente" : "Vencido"
    }

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
                    Sticker(text: statusLabel(at: timeline.date),
                            color: isOpen(at: timeline.date) ? Palette.green : Palette.coral,
                            icon: isOpen(at: timeline.date) ? "checkmark.circle" : "clock.badge.exclamationmark")
                    if store.pendingReports(for: menu) > 0 {
                        Sticker(text: "Reporte pendiente", color: Palette.coral, icon: "exclamationmark.circle")
                    }
                }
                validityCard
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
                                Text("Último reporte: \(SpanishPresentation.time(updated))")
                                    .font(.caption)
                            }
                        } else {
                            NavigationLink(destination: InsufficientQueueEvidenceView(menu: menu)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    InsufficientEvidenceView(count: menu.waitSampleCount)
                                    Label("Ver por qué no hay estimación", systemImage: "arrow.right")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Palette.ink)
                                }
                            }
                            .buttonStyle(.plain)
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
                                    Text(dish.dietaryKnown ? (dish.dietaryTags.isEmpty ? "Dieta declarada" : SpanishPresentation.dietaryTags(dish.dietaryTags)) : "Dieta sin confirmar")
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
                        Text("Válido hasta \(SpanishPresentation.dateAndTime(menu.validUntil))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isOpen(at: timeline.date) {
                    SolidButton(title: "Elegir este menú", icon: "checkmark", color: Palette.yellow) {
                        store.track("selection", menu: menu)
                    }
                    SolidButton(title: "Reportar un cambio", icon: "exclamationmark.bubble", color: Palette.coral) {
                        Task { await openReport() }
                    }
                    .disabled(isLoading)
                } else {
                    Text(isGone ? (loadError?.message ?? "Esta publicación ya no está disponible.")
                                : "Esta publicación venció. Vuelve a la lista de menús para ver opciones vigentes.")
                        .font(.subheadline.weight(.bold))
                        .padding(12)
                        .background(Palette.coral.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
        .background(Palette.cream)
        .navigationBarTitleDisplayMode(.inline)
        // Al cerrar la hoja se vuelve a pedir el detalle para ver el reporte como pendiente.
        .sheet(isPresented: $showingReport, onDismiss: { Task { await load() } }) { ReportSheet(menu: menu) }
        .onAppear { store.track("detail_open", menu: initialMenu) }
        .task { await load() }
        }
    }

    /// Vigencia, versión y cambios reportados de la versión consultada (BQ-04).
    @ViewBuilder private var validityCard: some View {
        if let loadError {
            Label(bannerText(for: loadError), systemImage: isGone ? "xmark.octagon" : "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((isGone ? Palette.coral : Palette.yellow).opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        if store.isRemote {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Vigencia y cambios reportados", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Text("Versión \(menu.version) · publicada \(SpanishPresentation.time(menu.publishedAt)) · vence \(SpanishPresentation.time(menu.validUntil))")
                        .font(.subheadline)
                    if let detail {
                        if detail.menu.version > initialMenu.version {
                            Text("El restaurante actualizó este menú: estás viendo la versión \(detail.menu.version).")
                                .font(.caption.weight(.semibold))
                        }
                        if detail.pendingReports.isEmpty {
                            Text("Sin cambios reportados pendientes en esta versión.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(detail.pendingReports) { report in
                                HStack {
                                    Image(systemName: "exclamationmark.bubble")
                                    Text(report.kindLabel)
                                    Spacer()
                                    Text(SpanishPresentation.time(report.createdAt)).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            Text("Los reportes pendientes no cambian el menú oficial hasta que se revisen.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Datos del servidor: \(SpanishPresentation.time(detail.serverNow))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if isLoading {
                        ProgressView("Consultando la versión actual…")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bannerText(for failure: APIFailure) -> String {
        switch failure.code {
        case "OFFLINE":
            return "Sin conexión: se muestra la copia guardada a las \(SpanishPresentation.time(store.cachedAt)); puede haber cambios."
        case "GONE", "NOT_FOUND":
            return failure.message
        default:
            return "No se pudo actualizar el detalle: \(failure.message)"
        }
    }

    /// Pide la versión actual al servidor. En modo demo no hace nada y se usa la copia local.
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let fresh = try await store.menuDetail(initialMenu) { detail = fresh }
            loadError = nil
        } catch let failure as APIFailure {
            loadError = failure
        } catch {
            loadError = APIFailure.unexpected
        }
    }

    /// Recarga antes de abrir la hoja para que el reporte quede ligado a la versión vigente.
    private func openReport() async {
        await load()
        if isOpen(at: .now) { showingReport = true }
    }
}

struct InsufficientEvidenceView: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Información insuficiente", systemImage: "hourglass")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
            Text("Hay \(count) reporte(s) en los últimos 30 minutos. Se necesitan al menos tres para mostrar una estimación.")
                .font(.subheadline)
            Text("Puedes informar el tiempo de fila después de visitar el local.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
    }
}
