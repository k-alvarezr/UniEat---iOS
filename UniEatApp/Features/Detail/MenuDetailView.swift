import MapKit
import SwiftUI
import UniEatCore

/// detalle del menu BQ-04, sigue vigente y que cambios reportaron
/// muestra de una la copia del feed y luego la cambia por la version actual del server
struct MenuDetailView: View {
    @EnvironmentObject private var app: AppStore
    let menu: DailyMenu
    var body: some View { MenuDetailScreen(model: app.makeDetail(menu)) }
}

private struct MenuDetailScreen: View {
    @StateObject private var store: MenuDetailViewModel
    @State private var showingReport = false
    // gps para decir que tan lejos queda el local, se lee una vez y no se guarda ni se manda
    @StateObject private var location = LocationContextService()

    init(model: MenuDetailViewModel) { _store = StateObject(wrappedValue: model) }
    private var initialMenu: DailyMenu { store.initialMenu }
    private var detail: MenuDetail? { store.detail }
    private var loadError: APIFailure? { store.loadError }
    private var isLoading: Bool { store.isLoading }

    /// la version del server si ya llego, si no la de la tarjeta
    private var menu: DailyMenu { store.menu }

    /// el server dijo 410 vencido o cerrado o 404
    private var isGone: Bool { store.isGone }

    /// se puede elegir o reportar ahora, usa el estado del server avanzado con el reloj
    private func isOpen(at date: Date) -> Bool {
        store.isOpen()
    }

    private func statusLabel(at date: Date) -> String {
        store.statusLabel()
    }

    var body: some View {
        // se redibuja cada minuto para que pase solo de vigente a por vencer y a vencido
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BrandHeader(title: "Detalle del plato")
                    FoodArtwork(name: menu.establishmentName, photoUrl: menu.photoUrl).frame(height: 180)
                    titleRow
                    statusRow(at: store.clock.now)
                    validityCard
                    waitCard(at: store.clock.now)
                    dishesSection
                    locationCard
                    paymentCard
                    actions(at: store.clock.now)
                }
                .padding(16)
            }
            .background(Palette.cream)
            .navigationBarTitleDisplayMode(.inline)
            // al cerrar la hoja se recarga para ver el reporte que se acabo de mandar
            .sheet(isPresented: $showingReport, onDismiss: { Task { await load(automatic: true) } }) {
                ReportSheet(menu: menu)
            }
            .onAppear {
                store.track("detail_open", menu: initialMenu)
                // si ya dio permiso se calcula la distancia sola, si no queda el boton
                if location.isAuthorized { location.request() }
            }
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
                if !store.showsWaitIndicator {
                    Text("El indicador no se muestra durante esta sesión de evaluación.").font(.subheadline)
                } else if menu.hasWaitEvidence(at: date), let wait = menu.waitMinutes {
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
                    Button("Abrir indicaciones") {
                        store.track("location_open", menu: menu)
                        openWalkingDirections(to: coordinate)
                    }
                    .font(.subheadline.weight(.bold))
                    distanceRow(to: CLLocation(latitude: latitude, longitude: longitude))
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
            // si ya lo eligio en esta sesion el boton queda como hecho y no se puede volver a tocar
            let chosen = store.wasChosen(menu)
            SolidButton(title: chosen ? "Elegiste este menú" : "Elegir este menú",
                        icon: chosen ? "checkmark.circle.fill" : "checkmark",
                        color: chosen ? Palette.green : Palette.yellow) {
                store.choose()
            }
            .disabled(chosen)
            // despues de elegir aparece llegue al local, cuenta una vez y queda como hecho
            if chosen {
                let arrived = store.hasArrived(menu)
                SolidButton(title: arrived ? "Llegaste, buen provecho" : "Llegué al local",
                            icon: arrived ? "checkmark.circle.fill" : "figure.walk",
                            color: arrived ? Palette.green : Palette.cyan) {
                    store.arrive()
                }
                .disabled(arrived)
                // ya en el local puede decir cuanta fila hay, al mandarla se recarga para ver la estimacion
                if arrived {
                    WaitTimeCard(menu: menu) { await load(automatic: true) }
                }
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

    /// abre apple maps con la ruta a pie hasta el local, desde donde este el celular
    private func openWalkingDirections(to coordinate: CLLocationCoordinate2D) {
        let local = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        local.name = menu.establishmentName   // para que el pin salga con el nombre del local
        local.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// que tan lejos queda el local, o el boton para preguntarlo
    @ViewBuilder
    private func distanceRow(to local: CLLocation) -> some View {
        if let here = location.location {
            Label(distanceText(here.distance(from: local)), systemImage: "figure.walk")
                .font(.subheadline.weight(.semibold))
        } else {
            Button {
                location.request()
            } label: {
                Label("Ver qué tan lejos queda", systemImage: "location")
            }
            .font(.subheadline.weight(.bold))
            // si no hay permiso o la lectura es mala, el servicio deja el mensaje
            if let message = location.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// distancia en linea recta, redondeada porque el gps puede fallar hasta 500 m,
    /// y minutos caminando contando 80 m por minuto
    private func distanceText(_ meters: CLLocationDistance) -> String {
        let minutes = max(1, Int((meters / 80).rounded(.up)))
        if meters < 1_000 {
            let rounded = Int((meters / 50).rounded()) * 50
            return "A unos \(max(50, rounded)) m en línea recta; caminata orientativa de ~\(minutes) min"
        }
        let km = (meters / 100).rounded() / 10
        return "A unos \(km) km en línea recta; caminata orientativa de ~\(minutes) min"
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

    private func load(automatic: Bool = false) async { await store.load(automatic: automatic) }

    /// recarga antes de abrir la hoja para que el reporte quede con la version actual
    /// y si cerraron el menu mientras tanto no se abre
    private func openReport() async {
        if await store.canReport() { showingReport = true }
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
