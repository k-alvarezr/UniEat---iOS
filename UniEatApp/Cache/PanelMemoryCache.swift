import Foundation

/// ultimos paneles de rendimiento en memoria con NSCache, llave = dias del periodo
/// son pocos pero pesados (BQ-03, BQ-04, BQ-08 y actividad), si iOS se queda sin memoria NSCache los bota solo
/// mejor perder un panel que se vuelve a pedir que hacer que el sistema cierre la app
@MainActor
final class PanelMemoryCache<Panel> {
    // NSCache solo guarda clases, por eso el panel va dentro de esta caja
    private final class Box {
        let panel: Panel
        init(_ panel: Panel) { self.panel = panel }
    }
    private let cache = NSCache<NSNumber, Box>()
    init() {
        cache.countLimit = 2   // hoy 7 y 28 dias, si agregamos mas periodos esto se amplia
    }

    /// el panel de ese periodo si NSCache no lo ha botado
    func value(days: Int) -> Panel? { cache.object(forKey: NSNumber(value: days))?.panel }

    /// guarda o reemplaza el panel de ese periodo
    func insert(_ panel: Panel, days: Int) { cache.setObject(Box(panel), forKey: NSNumber(value: days)) }

    /// al cambiar de cuenta se bota todo
    func clear() { cache.removeAllObjects() }
}
