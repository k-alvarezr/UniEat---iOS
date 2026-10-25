import MapKit
import SwiftUI
import UniEatCore

/// detalle del menu BQ-04, sigue vigente y que cambios reportaron
/// muestra de una la copia del feed y luego la cambia por la version actual del server
struct MenuDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    private let initialMenu: DailyMenu
    @State private var detail: MenuDetail?
    @State private var loadError: APIFailure?
    @State private var isLoading = false
    @State private var showingReport = false

    init(menu: DailyMenu) { initialMenu = menu }

    /// la version del server si ya llego, si no la de la tarjeta
    private var menu: DailyMenu { detail?.menu ?? initialMenu }

    /// el server dijo 410 vencido o cerrado o 404
    private var isGone: Bool { ["GONE", "NOT_FOUND"].contains(loadError?.code ?? "") }

    /// se puede elegir o reportar ahora, usa el estado del server avanzado con el reloj
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
        // se redibuja cada minuto para que pase solo de vigente a por vencer y a vencido
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandHeader(title: "Detalle del plato")
                    FoodArtwork(name: menu.establishmentName, photoUrl: menu.photoUrl).frame(height: 180)
                    titleRow
                    statusRow(at: timeline.date)
                    validityCard
                    waitCard(at: timeline.date)
                    dishesSection
                    locationCard
                    paymentCard
                    actions(at: timeline.date)
                }
                .padding(16)
            }
            .background(Palette.cream)
            .navigationBarTitleDisplayMode(.inline)
            // al cerrar la hoja se recarga para ver el reporte que se acabo de mandar
            .sheet(isPresented: $showingReport, onDismiss: { Task { await load(automatic: true) } }) {
                ReportSheet(menu: menu)
            }
            .onAppear { store.track("detail_open", menu: initialMenu) }
            .task { await load() }
        }
    }

    // MARK: - partes de la pantalla

    private var titleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(menu.establishmentName).font(.rounded(25))
                Text(menu.title).font(.subheadline)
            }
            Spacer()
            Sticker(text: "Desde \(menu.lowestPriceCop.cop)", color: Palette.yellow)
        }
    }

    private func statusRow(at date: Date) -> some View {
        let open = isOpen(at: date)
        return HStack(spacing: 8) {
            Sticker(text: menu.area, color: Palette.cyan, icon: "mappin")
            Sticker(text: statusLabel(at: date), color: open ? Palette.green : Palette.coral,
                    icon: open ? "checkmark.circle" : "clock.badge.exclamationmark")
            if menu.pendingReports > 0 {
                Sticker(text: "Reporte pendiente", color: Palette.coral, icon: "exclamationmark.circle")
            }
        }
    }

    /// esto es lo que se ve de BQ-04, version vigencia y cambios reportados
    @ViewBuilder private var validityCard: some View {
        if let loadError {
            Label(bannerText(for: loadError), systemImage: isGone ? "xmark.octagon" : "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((isGone ? Palette.coral : Palette.yellow).opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vigencia y cambios reportados", systemImage: "clock.arrow.circlepath").font(.headline)
                Text("Versión \(menu.version) · publicada \(SpanishPresentation.time(menu.publishedAt)) · vence \(SpanishPresentation.time(menu.validUntil))")
                    .font(.subheadline)
                if let detail {
                    reportedChanges(detail)
                } else if isLoading {
                    ProgressView("Consultando la versión actual…").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func reportedChanges(_ detail: MenuDetail) -> some View {
        if detail.isNewer(than: initialMenu.version) {
            Text("El restaurante actualizó este menú: estás viendo la versión \(detail.menu.version).")
                .font(.caption.weight(.semibold))
        }
        if detail.activeNotices.isEmpty {
            Text("Sin cambios reportados pendientes en esta versión.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(detail.activeNotices) { report in
                HStack {
                    Image(systemName: report.isPending ? "exclamationmark.bubble" : "checkmark.seal.fill")
                    Text(report.kindLabel)
                    Spacer()
                    Text(report.statusLabel).fontWeight(.semibold)
                    Text(SpanishPresentation.time(report.createdAt)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Text("Los reportes no cambian el menú oficial. Se confirman cuando un administrador los revisa o cuando tres estudiantes reportan lo mismo.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Text("Datos del servidor: \(SpanishPresentation.time(detail.serverNow))")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func waitCard(at date: Date) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Información de espera", systemImage: "clock").font(.headline)
                if menu.hasWaitEvidence(at: date), let wait = menu.waitMinutes {
                    Text("~\(wait) minutos").font(.rounded(30, .black))
                    Text("Estimación basada en \(menu.waitSampleCount) reportes recientes. No es un tiempo garantizado.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let updated = menu.waitNewestReportAt {
                        Text("Último reporte: \(SpanishPresentation.time(updated))").font(.caption)
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
    }

    private var dishesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menú del día").font(.rounded(20))
            ForEach(menu.items) { dish in
                SurfaceCard {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(dish.name).font(.rounded(16, .bold))
                            if !dish.description.isEmpty {
                                Text(dish.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(dietLabel(for: dish)).font(.caption)
                        }
                        Spacer()
                        Sticker(text: dish.priceCop.cop, color: Palette.yellow)
                    }
                }
            }
        }
    }

    private func dietLabel(for dish: MenuDish) -> String {
        guard dish.dietaryKnown else { return "Dieta sin confirmar" }
        return dish.dietaryTags.isEmpty ? "Dieta declarada" : SpanishPresentation.dietaryTags(dish.dietaryTags)
    }

    private var locationCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Ubicación exacta", systemImage: "map").font(.headline)
                if let latitude = menu.latitude, let longitude = menu.longitude {
                    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))) {
                        Marker(menu.establishmentName, coordinate: coordinate)
                    }
                    .frame(height: 175)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let mapURL = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") {
                        Button("Abrir indicaciones") {
                            store.track("location_open", menu: menu)
                            openURL(mapURL)
                        }
                        .font(.subheadline.weight(.bold))
                    }
                } else {
                    Text("Ubicación no confirmada").font(.subheadline)
                }
                Text(menu.address.isEmpty ? "Dirección no publicada" : menu.address)
                if !menu.entranceDescription.isEmpty {
                    Text(menu.entranceDescription).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var paymentCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("Medios de pago").font(.headline)
                Text(menu.paymentMethods.isEmpty ? "Sin información declarada" : menu.paymentMethods.joined(separator: " · "))
                Text("Válido hasta \(SpanishPresentation.dateAndTime(menu.validUntil))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actions(at date: Date) -> some View {
        let open = isOpen(at: date)
        let saved = store.isSaved(menu)
        if open || saved {
            SolidButton(title: saved ? "Quitar de guardados" : "Guardar menú",
                        icon: saved ? "bookmark.slash" : "bookmark", color: Palette.cyan) {
                store.toggleSaved(menu)
            }
        }
        if open {
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

    // MARK: - cargar

    private func bannerText(for failure: APIFailure) -> String {
        switch failure.code {
        case "OFFLINE":
            return "Sin conexión: se muestra la copia guardada a las \(SpanishPresentation.time(store.fetchedAt)); puede haber cambios."
        case "GONE", "NOT_FOUND":
            return failure.message
        default:
            return "No se pudo actualizar el detalle: \(failure.message)"
        }
    }

    private func load(automatic: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await store.menuDetail(initialMenu, automatic: automatic)
            loadError = nil
        } catch let failure as APIFailure {
            loadError = failure
        } catch {
            loadError = .unexpected
        }
    }

    /// recarga antes de abrir la hoja para que el reporte quede con la version actual
    /// y si cerraron el menu mientras tanto no se abre
    private func openReport() async {
        await load(automatic: true)
        if isOpen(at: .now) { showingReport = true }
    }
}

struct InsufficientEvidenceView: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Información insuficiente", systemImage: "hourglass").font(.rounded(17))
            Text("Hay \(count) reporte(s) en los últimos 30 minutos. Se necesitan al menos tres para mostrar una estimación.")
                .font(.subheadline)
            Text("Puedes informar el tiempo de fila después de visitar el local.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Palette.cream, in: RoundedRectangle(cornerRadius: 10))
    }
}
