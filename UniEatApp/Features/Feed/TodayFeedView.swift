import SwiftUI
import Kingfisher
import UniEatCore

struct TodayFeedView: View {
    var body: some View {
        NavigationStack { TodayFeedContent(hidesNavigationBar: true) }
    }
}

/// pestaña hoy BQ-03, menus vigentes en el orden del server con su motivo
struct TodayFeedContent: View {
    @EnvironmentObject private var store: FeedViewModel
    var hidesNavigationBar = false

    var body: some View {
        // se redibuja cada minuto para que por vencer y vencido cambien solos
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    BrandHeader(title: "UniEat · Hoy")
                    header(date: timeline.date)
                    // al abrir se muestra la copia mientras llega el server, eso no es estar sin conexion
                    // el aviso sale solo si no hay red o si la carga ya termino y no se pudo actualizar
                    if store.isOffline || (store.isShowingCachedFeed && !store.isLoading) {
                        NavigationLink(destination: OfflineFeedView()) {
                            OfflineNotice(fetchedAt: store.fetchedAt)
                        }
                        .buttonStyle(.plain)
                    } else if store.isShowingCachedFeed {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Actualizando menús…").font(.footnote.weight(.semibold))
                        }
                    }
                    recommendationShortcut
                    sectionTitle
                    if let error = store.loadError {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).font(.footnote)
                                Button("Reintentar actualización") { Task { await store.refresh(force: true) } }
                            }
                        }
                    }
                    if let warning = store.cacheWarning {
                        Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.footnote).foregroundStyle(Palette.coral)
                    }
                    if store.isLoading && store.visibleMenus.isEmpty {
                        ProgressView("Cargando menús…")
                    } else if store.visibleMenus.isEmpty && store.loadError != nil {
                        ContentUnavailableView("No se pudo actualizar el feed", systemImage: "arrow.clockwise",
                            description: Text("Reintenta cuando el servicio esté disponible."))
                    } else if store.visibleMenus.isEmpty {
                        EmptyFeedView()
                    } else {
                        ForEach(store.visibleMenus) { menu in
                            NavigationLink(destination: MenuDetailView(menu: menu)) {
                                MenuCard(menu: menu, at: store.clock.now)
                            }
                            .buttonStyle(.plain)
                            .onAppear { store.track("feed_impression", menu: menu) }
                        }
                        .id(store.contentRevision)
                    }
                }
                .padding(16)
            }
        }
        .background(Palette.cream)
        .navigationBarHidden(hidesNavigationBar)
        .refreshable { await store.refresh(force: true) }
    }

    private func header(date: Date) -> some View {
        HStack(spacing: 8) {
            Sticker(text: SpanishPresentation.dayAndMonth(date), color: Palette.yellow, icon: "calendar")
            Spacer()
            if let budget = store.filters.budgetCop {
                Sticker(text: "Hasta \(budget.cop)", color: Palette.green)
            }
        }
    }

    private var recommendationShortcut: some View {
        NavigationLink(destination: RecommendationView()) {
            HStack {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿SORTEAR AHORA?").fontWeight(.heavy)
                    Text("Una opción que cumple tus filtros").font(.caption)
                }
                Spacer()
                Image(systemName: "arrow.right")
            }
            .foregroundStyle(Palette.ink)
            .padding(13)
            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
        }
    }

    private var sectionTitle: some View {
        HStack {
            Text("Menús vigentes").font(.rounded(25))
            Spacer()
            NavigationLink(destination: FiltersView()) {
                Label("Filtros", systemImage: "slider.horizontal.3").font(.rounded(13, .bold))
            }
        }
    }
}

/// tarjeta del menu, lo que se ve de BQ-03
struct MenuCard: View {
    @EnvironmentObject private var pilot: WaitIndicatorPilot
    let menu: DailyMenu
    let date: Date

    init(menu: DailyMenu, at date: Date = .now) {
        self.menu = menu
        self.date = date
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                FoodArtwork(name: menu.establishmentName, photoUrl: menu.photoUrl)
                    .frame(height: 130)
                HStack(alignment: .firstTextBaseline) {
                    Text(menu.establishmentName).font(.rounded(18))
                    Spacer()
                    Sticker(text: menu.lowestPriceCop.cop, color: Palette.yellow)
                }
                Text(menu.title).font(.rounded(14, .bold))
                HStack(spacing: 7) {
                    Sticker(text: menu.area, color: Palette.cyan, icon: "mappin")
                    if !pilot.showsWaitIndicator {
                        Sticker(text: "Evaluación en curso", color: Palette.cream, icon: "clock")
                    } else if let wait = menu.waitMinutes, menu.hasWaitEvidence(at: date) {
                        Sticker(text: "~\(wait) min de fila", color: Palette.green, icon: "clock")
                    } else {
                        Sticker(text: "Fila sin datos", color: Palette.cream, icon: "clock")
                    }
                }
                if menu.pendingReports > 0 {
                    Label("\(menu.pendingReports) reporte(s) pendiente(s) de verificar", systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(Palette.coral)
                }
                if PublicationAssessment(menu: menu, at: date).state == .expiring {
                    Label("Menú por vencer", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(Palette.coral)
                }
                Text(pilot.explanation(menu.explanation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Palette.ink)
    }
}

/// foto del local si tiene url https, si no un dibujo con el nombre
struct FoodArtwork: View {
    @EnvironmentObject private var app: AppStore
    @State private var localPhoto: URL?
    let name: String
    var photoUrl: String?

    private var photo: URL? {
        guard let photoUrl, let url = URL(string: photoUrl), url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.yellow, Palette.coral.opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.45)).frame(width: 140).offset(x: 95, y: -40)
            if photo == nil { placeholderIcon }
        }
        // la foto va como overlay para que tome el tamaño del cuadro y no al reves
        // con scaledToFill adentro del zstack la foto crecia y tapaba la tarjeta de abajo
        .overlay {
            if let photo {
                KFImage(source: localPhoto.map {
                    .provider(LocalFileImageDataProvider(fileURL: $0, cacheKey: photo.absoluteString))
                } ?? .network(ImageResource(downloadURL: photo)))
                .placeholder { placeholderIcon }
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 720, height: 480)))
                .cacheOriginalImage()
                .onlyFromCache(app.connectivity.isOffline && localPhoto == nil)
                .cancelOnDisappear(true)
                .resizable().scaledToFill()
            }
        }
        // el nombre va encima de la foto para que se siga viendo
        .overlay(alignment: .bottomLeading) {
            Text(name.uppercased())
                .font(.rounded(12, .black))
                .padding(7)
                .background(Palette.paper, in: Capsule())
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityLabel(photo == nil ? "Ilustración de \(name)" : "Foto de \(name)")
        .task(id: photo?.absoluteString) {
            localPhoto = nil
            if let photo { localPhoto = await app.images.localFile(photo) }
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "fork.knife.circle.fill")
            .font(.system(size: 68))
            .foregroundStyle(Palette.ink.opacity(0.75))
    }
}

struct OfflineNotice: View {
    let fetchedAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Vista guardada · puede haber cambios").fontWeight(.heavy)
                Text("Última carga: \(SpanishPresentation.dateAndTime(fetchedAt)); los menús vencidos se ocultan.")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink, lineWidth: 2))
    }
}

struct EmptyFeedView: View {
    var body: some View {
        SurfaceCard {
            VStack(spacing: 10) {
                Image(systemName: "fork.knife.circle").font(.system(size: 48))
                Text("No hay menús que cumplan estos filtros").font(.headline)
                Text("Prueba otro presupuesto, zona o preferencia de dieta.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
