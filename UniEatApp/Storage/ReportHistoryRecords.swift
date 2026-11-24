import Foundation
import SwiftData

/// copia local de Mis reportes: un restaurante del usuario con sus reportes
/// ReportedRestaurantRecord 1 -> N UserReportRecord, si se borra el restaurante se borran sus reportes en cascada
/// vive en la misma base que la cola de reportes, se lee y escribe desde LocalDatabase
@Model
final class ReportedRestaurantRecord {
    var userID: UUID
    var establishmentID: UUID
    var name: String
    var area: String
    // conteo por estado como lo manda el server, para pintar la lista sin abrir los reportes
    var total: Int
    var pending: Int
    var confirmed: Int
    var dismissed: Int
    var lastReportAt: Date
    @Relationship(deleteRule: .cascade, inverse: \UserReportRecord.restaurant)
    var reports: [UserReportRecord] = []

    init(userID: UUID, restaurant: ReportedRestaurant) {
        self.userID = userID
        establishmentID = restaurant.establishmentId
        name = restaurant.name
        area = restaurant.area
        total = restaurant.total
        pending = restaurant.pending
        confirmed = restaurant.confirmed
        dismissed = restaurant.dismissed
        lastReportAt = restaurant.lastReportAt
    }

    /// pone el resumen que mando el server, no toca los reportes
    func applySummary(from restaurant: ReportedRestaurant) {
        name = restaurant.name
        area = restaurant.area
        total = restaurant.total
        pending = restaurant.pending
        confirmed = restaurant.confirmed
        dismissed = restaurant.dismissed
        lastReportAt = restaurant.lastReportAt
    }

    /// copia Sendable para la pantalla
    var asReportedRestaurant: ReportedRestaurant {
        ReportedRestaurant(establishmentId: establishmentID, name: name, area: area,
                           total: total, pending: pending, confirmed: confirmed, dismissed: dismissed,
                           lastReportAt: lastReportAt)
    }
}

/// un reporte del usuario en ese restaurante, tal como lo devolvio el server
@Model
final class UserReportRecord {
    var reportID: UUID
    var kind: String
    var version: Int
    var menuTitle: String
    var note: String
    var observedWaitMinutes: Int?
    var status: String
    var resolutionSource: String?
    var observedAt: Date
    var resolvedAt: Date?
    var restaurant: ReportedRestaurantRecord?

    init(report: UserReport) {
        reportID = report.id
        kind = report.kind
        version = report.version
        menuTitle = report.menuTitle
        note = report.note
        observedWaitMinutes = report.observedWaitMinutes
        status = report.status
        resolutionSource = report.resolutionSource
        observedAt = report.observedAt
        resolvedAt = report.resolvedAt
    }

    var asUserReport: UserReport {
        UserReport(id: reportID, kind: kind, version: version,
                           menuTitle: menuTitle, note: note, observedWaitMinutes: observedWaitMinutes,
                           status: status, resolutionSource: resolutionSource,
                           observedAt: observedAt, resolvedAt: resolvedAt)
    }
}

/// Mis reportes en la base, igual que la cola de reportes: contexto principal y save al final
extension LocalDatabase {
    /// restaurantes guardados del usuario, el del reporte mas reciente primero
    func loadReportedRestaurants(userId: UUID) throws -> [ReportedRestaurant] {
        var descriptor = FetchDescriptor<ReportedRestaurantRecord>(predicate: #Predicate { $0.userID == userId })
        descriptor.sortBy = [SortDescriptor(\.lastReportAt, order: .reverse)]
        return try container.mainContext.fetch(descriptor).map(\.asReportedRestaurant)
    }

    /// la lista del server reemplaza la del usuario
    /// los restaurantes que siguen solo cambian su resumen (asi no se pierden sus reportes guardados),
    /// los nuevos se agregan y los que ya no estan se borran con sus reportes
    func replaceReportedRestaurants(_ restaurants: [ReportedRestaurant], userId: UUID) throws {
        let context = container.mainContext
        let saved = try context.fetch(FetchDescriptor<ReportedRestaurantRecord>(predicate: #Predicate { $0.userID == userId }))
        // los que quedan en este diccionario al final son los que el server ya no manda
        var notInServer = Dictionary(saved.map { ($0.establishmentID, $0) }, uniquingKeysWith: { first, _ in first })
        for restaurant in restaurants {
            if let record = notInServer.removeValue(forKey: restaurant.establishmentId) { record.applySummary(from: restaurant) }
            else { context.insert(ReportedRestaurantRecord(userID: userId, restaurant: restaurant)) }
        }
        for record in notInServer.values { context.delete(record) }
        try commitOrRollback()
    }

    /// reportes guardados de un restaurante, el mas reciente primero, vacio si nunca se bajaron
    func loadUserReports(userId: UUID, establishmentId: UUID) throws -> [UserReport] {
        try findRestaurantRecord(userId: userId, establishmentId: establishmentId)?.reports
            .sorted { $0.observedAt > $1.observedAt }.map(\.asUserReport) ?? []
    }

    /// el detalle del server reemplaza los reportes de ese restaurante
    func replaceUserReports(_ reports: [UserReport], restaurant: ReportedRestaurant, userId: UUID) throws {
        let context = container.mainContext
        let record: ReportedRestaurantRecord
        if let found = try findRestaurantRecord(userId: userId, establishmentId: restaurant.establishmentId) {
            record = found
            record.applySummary(from: restaurant)
            for oldReport in record.reports { context.delete(oldReport) }
        } else {
            record = ReportedRestaurantRecord(userID: userId, restaurant: restaurant)
            context.insert(record)
        }
        for report in reports {
            let reportRecord = UserReportRecord(report: report)
            context.insert(reportRecord)
            reportRecord.restaurant = record
        }
        try commitOrRollback()
    }

    /// cerrar sesion: se borra la copia de esa cuenta, el cascade se lleva sus reportes
    func deleteReportHistory(userId: UUID) throws {
        let context = container.mainContext
        for record in try context.fetch(FetchDescriptor<ReportedRestaurantRecord>(predicate: #Predicate { $0.userID == userId })) {
            context.delete(record)
        }
        try commitOrRollback()
    }

    private func findRestaurantRecord(userId: UUID, establishmentId: UUID) throws -> ReportedRestaurantRecord? {
        try container.mainContext.fetch(FetchDescriptor<ReportedRestaurantRecord>(
            predicate: #Predicate { $0.userID == userId && $0.establishmentID == establishmentId })).first
    }

    // si no se pudo guardar se deshace lo que se metio al contexto, como en enqueueReport
    private func commitOrRollback() throws {
        do { try container.mainContext.save() }
        catch {
            container.mainContext.rollback()
            throw error
        }
    }
}
