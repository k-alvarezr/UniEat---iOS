import Foundation

/// reloj de la app con la hora del server y no la del celular
/// cuando llega una respuesta se guarda cuanto va adelantado o atrasado el server respecto al celular
/// y desde ahi la hora es la del celular mas esa diferencia, si no ha llegado nada se usa la del celular
/// asi un celular con la hora mal puesta no daña la vigencia ni la hora de los reportes
/// no avisa a las pantallas: se redibujan con los datos que llegan en la misma respuesta
@MainActor
final class ServerClock {
    private var offset: TimeInterval = 0   // segundos que el server va adelante (o atras si es negativo) del celular
    private let wallTime: () -> Date       // hora del celular, se inyecta para poder probarlo
    init(wallTime: @escaping () -> Date = { .now }) {
        self.wallTime = wallTime
    }
    /// hora actual segun el server
    var now: Date { wallTime().addingTimeInterval(offset) }
    /// se llama con cada respuesta que trae la hora del server
    func synchronize(_ serverNow: Date) {
        offset = serverNow.timeIntervalSince(wallTime())
    }
}
