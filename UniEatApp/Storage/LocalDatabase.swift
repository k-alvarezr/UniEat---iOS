import Foundation
import SwiftData
import UniEatCore

/// version de un menu que vio el estudiante, una fila por usuario menu y version
/// es la tabla padre de los reportes que quedan sin mandar
@Model
final class MenuSnapshot {
    @Attribute(.unique) var key: String // usuario:menu:version, para no repetir filas
    var userId: UUID
        var menuId: UUID
        var version: Int
        var title: String
        var establishmentName: String
        var seenAt: Date
    // si se borra snapshot, se borra de ahi para abajo en cascada lo asociado (los reportes relacionados)
    @Relationship(deleteRule: .cascade, inverse: \PendingReport.snapshot)
    var reports: [PendingReport] = []
    
    // inicializacion
    init(userId: UUID, menu: DailyMenu) {
        key = Self.key(userId, menu.id, menu.version)
        self.userId = userId
        menuId = menu.id
        version = menu.version
        title = menu.title
        establishmentName = menu.establishmentName
        seenAt = .now
    }
    
    static func key(_ userId: UUID, _ menuId: UUID, _ version: Int) -> String {
        "\(userId.uuidString):\(menuId.uuidString):\(version)"
    }
}

/// reporte que se hizo sin red o que fallo al mandarse, cuelga de la version que vio el estudiante
@Model
final class PendingReport{
    var id: UUID
    var kind: String
    var note: String
    var waitMinutes: Int?
    var createdAt: Date
    var snapshot: MenuSnapshot?
    // motivo si el server lo rechazo, nil si sigue esperando para mandarse
    // es opcional para que swiftdata migre solo la base que ya existe
    var rejectedReason: String?
    
    init(kind: String, note: String, waitMinutes: Int?) {
        id = UUID()
        self.kind = kind
        self.note = note
        self.waitMinutes = waitMinutes
        createdAt = .now
    }
    
    /// arma lo que se manda al server con la version que vio el estudiante al reportar
    /// si el menu cambio mientras no habia red el reporte no le cae a la version nueva
    var body: ReportBody? {
        guard let snapshot else {return nil}
        return ReportBody(publicationId: snapshot.menuId,
                          version: snapshot.version,
                          kind: kind,
                          note: note, observedWaitMinutes: waitMinutes,
                          // el id y la hora del reporte van al server para no duplicar al reintentar
                          clientReportId: id, observedAt: createdAt)
    }
}

/// acceso a la base local, el resto de la app no toca SwiftData directo
/// si un dia se quiere usar Core Data u otros, es mas modular solo hacerlo desde aca
@MainActor
final class LocalDatabase {
    let container: ModelContainer // esta es perse la BD local, archivo con esquemas y modelos
    private var context: ModelContext {container.mainContext} // contexto asociado al hilo principal
    
    /// lanza el error si la base no abre, inMemory y storeURL son para las pruebas
    init(inMemory: Bool = false, storeURL: URL? = nil) throws {
        // todos los modelos de la app van en esta lista: reportes (#33), guardados y copias del feed (#34)
        let schema = Schema([MenuSnapshot.self, PendingReport.self, SavedMenu.self, SavedDish.self, FeedCacheRecord.self])
        let config = storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        // si no abre no se borra el archivo, puede tener reportes del usuario
        // AppStore sigue sin base y Perfil avisa del problema
        container = try ModelContainer(for: schema, configurations: config)
    }
    
    /// guarda el reporte colgado del snapshot de esa version, si el snapshot no existe se crea
    /// recibe el id y la hora desde afuera para que el mismo reporte conserve su id al reintentar
    /// y lanza el error si no se pudo guardar, para no decirle al usuario que quedo guardado cuando no
    func enqueueReport(userId: UUID, menu: DailyMenu, kind: String, note: String, waitMinutes: Int?,
                       id: UUID = UUID(), observedAt: Date = .now) throws {
        let key = MenuSnapshot.key(userId, menu.id, menu.version)
        let found = try context.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.key == key }))
        let snapshot = found.first ?? MenuSnapshot(userId: userId, menu: menu)
        if found.first == nil { context.insert(snapshot) }
        let report = PendingReport(kind: kind, note: note, waitMinutes: waitMinutes)
        report.id = id
        report.createdAt = observedAt
        context.insert(report)
        report.snapshot = snapshot
        // si no se pudo guardar se deshace lo que se metio al contexto
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
    
    /// reportes sin mandar de este usuario, del mas viejo al mas nuevo
    /// se buscan los snapshots del usuario y se recorren sus reportes por la relacion
    func pendingReports(userId: UUID) throws -> [PendingReport] {
        let snapshots = try context.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.userId == userId }))
        var reports: [PendingReport] = []
        for snapshot in snapshots { reports += snapshot.reports }
        return reports.sorted { $0.createdAt < $1.createdAt }
    }
    
    /// borra un reporte ya mandado, si su snapshot queda sin reportes tambien se borra
    func remove(_ report: PendingReport) throws {
        let snapshot = report.snapshot
        context.delete(report)
        if let snapshot, snapshot.reports.allSatisfy({ $0.id == report.id }) {
            context.delete(snapshot)
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// busca un reporte por id sin cargar toda la cola, solo si es de ese usuario
    /// el dueño se revisa por la relacion con el snapshot, otra cuenta no puede tocarlo
    func report(id: UUID, userId: UUID) throws -> PendingReport? {
        let found = try context.fetch(FetchDescriptor<PendingReport>(predicate: #Predicate { $0.id == id }))
        return found.first { $0.snapshot?.userId == userId }
    }

    /// marca el reporte como rechazado por el server con su motivo, no se borra
    func reject(_ report: PendingReport, reason: String) throws {
        report.rejectedReason = reason
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// quita la marca de rechazado a todos los reportes del usuario para volver a intentarlos
    func clearRejections(userId: UUID) throws {
        for report in try pendingReports(userId: userId) {
            report.rejectedReason = nil
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
