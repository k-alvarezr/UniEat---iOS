import Foundation

/// preferencias pequeñas de Mis reportes en UserDefaults (llave-valor), una llave por usuario
/// - el filtro elegido, para que al volver a la pantalla siga el mismo
/// - la hora del server de la ultima sincronizacion, para decir que tan vieja es la copia sin red
/// no van en swiftdata porque son un valor suelto por cuenta, no datos con relaciones
struct ReportHistoryPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func filterKey(_ userID: UUID) -> String { "unieat.report-history.filter.\(userID.uuidString)" }
    static func lastSyncDateKey(_ userID: UUID) -> String { "unieat.report-history.synced-at.\(userID.uuidString)" }

    /// filtro guardado, .all si nunca se eligio o si la opcion ya no existe
    func savedFilter(userID: UUID) -> ReportHistoryFilter {
        defaults.string(forKey: Self.filterKey(userID)).flatMap(ReportHistoryFilter.init(rawValue:)) ?? .all
    }
    func saveFilter(_ filter: ReportHistoryFilter, userID: UUID) {
        defaults.set(filter.rawValue, forKey: Self.filterKey(userID))
    }

    /// hora del server de la ultima lista bajada, nil si nunca se sincronizo
    func lastSyncDate(userID: UUID) -> Date? {
        defaults.object(forKey: Self.lastSyncDateKey(userID)) as? Date
    }
    func saveLastSyncDate(_ date: Date, userID: UUID) {
        defaults.set(date, forKey: Self.lastSyncDateKey(userID))
    }

    /// cerrar sesion: se borra lo de esa cuenta
    func deleteAll(userID: UUID) {
        defaults.removeObject(forKey: Self.filterKey(userID))
        defaults.removeObject(forKey: Self.lastSyncDateKey(userID))
    }
}
