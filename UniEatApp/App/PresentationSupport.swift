import Combine
import Foundation
import UniEatCore

/// papa de los viewmodels de cada pantalla
/// cuando cambia algo compartido (sesion, feed, red, reloj) avisa a la pantalla para que se redibuje,
/// asi cada viewmodel no tiene que copiar ese estado, solo lo lee de la fuente
@MainActor
class FeatureViewModel: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []   // suscripciones vivas mientras viva el viewmodel
    /// cada vez que object va a cambiar, este viewmodel tambien avisa que cambio
    func observe<T: ObservableObject>(_ object: T) {
        object.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

/// guardar y leer cosas pequeñas en UserDefaults como json (filtros, copia del feed, guardados)
/// es lo mismo que hacia el save y load del AppStore viejo, solo que aparte para que lo use cualquiera
enum LocalValues {
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? UniEatDates.encoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    /// borra lo guardado con esa llave
    static func remove(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
    /// nil si no hay nada con esa llave o si no se puede leer
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
}

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
