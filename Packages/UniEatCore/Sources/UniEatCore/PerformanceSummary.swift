import Foundation

public struct PerformanceSummary: Codable, Sendable {
    public let periodDays: Int           // periodo de las cifras, 7 o 28 dias
    public let impressions: Int          // cuantas veces se vio una tarjeta en el feed
    public let detailOpens: Int          // cuantas veces se abrio el detalle de un menu
    public let selections: Int           // cuantas veces se selecciono "elegir este menu"
    public let reportedArrivals: Int     // cuantas veces dijeron "llegue al local"
    public let savedMenus: Int           // cuantas personas distintas guardaron un menu en el periodo
    public let locationOpens: Int        // cuantas veces abrieron "abrir indicaciones"
    public let reports: Int              // cuantos reportes se enviaron
    public let sampleSize: Int?          // cuantas sesiones distintas hicieron almenos una accion en el periodo
    public let insufficientData: Bool?   // true si hay pocos datos para sacar porcentajes (menos de 5 sesiones o cero impresiones)
    public let rates: PerformanceRates?  // los porcentajes, vacios si hay insufficientData
}
