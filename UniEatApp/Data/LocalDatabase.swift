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
                          note: note, observedWaitMinutes: waitMinutes)
    }
}

/// acceso a la base local, el resto de la app no toca SwiftData directo
/// si un dia se quiere usar Core Data u otros, es mas modular solo hacerlo desde aca
@MainActor
final class LocalDatabase {
    let container: ModelContainer // esta es perse la BD local, archivo con esquemas y modelos
    private var context: ModelContext {container.mainContext} // contexto asociado al hilo principal
    
    init() {
        // todos los modelos de la app van en esta lista
        let schema = Schema([MenuSnapshot.self, PendingReport.self])
        let config = ModelConfiguration(schema: schema)
        do {
            // se inicializa con normalidad
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // se puede caer si no abre la BD local, que puede pasar si se cambiaron cosas del modelo
            // para el usuario no tiene sentido, esto es offline, como actualizar sin internet
            // pero si en las actualizaciones mientras desarrollamos movemos algo, esto limpia y vuelve a generar
            // asi no desinstalamos e instalamos cada vez
            try? FileManager.default.removeItem(at: config.url)
            container = try! ModelContainer(for: schema, configurations: config)
        }
    }
    
    /// guarda el reporte colgado del snapshot de esa version, si el snapshot no existe se crea
    func enqueueReport(userId: UUID, menu: DailyMenu, kind: String, note: String, waitMinutes: Int?){
        let key = MenuSnapshot.key(userId, menu.id, menu.version)
        let found = try? context.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.key == key }))
        let snapshot = found?.first ?? MenuSnapshot(userId: userId, menu: menu) //crea
        if found?.first == nil { context.insert(snapshot) } //inserta
        let report = PendingReport(kind: kind, note: note, waitMinutes: waitMinutes)
        context.insert(report)
        report.snapshot = snapshot
        try? context.save()
    }
    
    /// reportes sin mandar de este usuario, del mas viejo al mas nuevo
    /// se buscan los snapshots del usuario y se recorren sus reportes por la relacion
    func pendingReports(userId: UUID) -> [PendingReport] {
        let snapshots = (try? context.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.userId == userId }))) ?? []
        var reports: [PendingReport] = []
        for snapshot in snapshots { reports += snapshot.reports }
        return reports.sorted { $0.createdAt < $1.createdAt }
    }
    
    /// borra un reporte ya mandado, si su snapshot queda sin reportes tambien se borra
    func remove(_ report: PendingReport) {
        let snapshot = report.snapshot
        context.delete(report)
        if let snapshot, snapshot.reports.allSatisfy({ $0.id == report.id }) {
            context.delete(snapshot)
        }
        try? context.save()
    }

    /// borra por id, para cuando el reporte se mando desde otro hilo y solo se tiene su id
    func remove(id:UUID) {
        let found = try? context.fetch(FetchDescriptor<PendingReport>(predicate: #Predicate { $0.id == id }))
        if let report = found?.first { remove(report) }
    }
    
    /// al cerrar sesion se borra todo lo del usuario, el cascade se lleva los reportes
    func deleteAll(userId: UUID) {
        let snapshots = (try? context.fetch(FetchDescriptor<MenuSnapshot>(predicate: #Predicate { $0.userId == userId }))) ?? []
        for snapshot in snapshots { context.delete(snapshot) }
        try? context.save()
    }
}
