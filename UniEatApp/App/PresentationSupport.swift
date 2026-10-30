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

/// Referencia que acompaña las copias. Tras relanzar sin red se estima el tiempo transcurrido;
/// durante el proceso se usa uptime y cambiar la hora del teléfono no altera la vigencia.
struct ServerTimeReference: Codable, Sendable {
    let serverNow: Date
    let receivedAt: Date
}

/// Reloj sin publicaciones ni redibujos: conserva la simplicidad de Juan, pero avanza
/// con tiempo monotónico después de recibir una hora del servidor.
@MainActor
final class ServerClock {
    private var reference: ServerTimeReference?
    private var uptimeAtReceipt: TimeInterval = 0
    private let uptime: () -> TimeInterval
    private let wallTime: () -> Date
    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallTime: @escaping () -> Date = { .now }) {
        self.uptime = uptime
        self.wallTime = wallTime
    }
    /// hora actual segun el server
    var now: Date {
        guard let reference else { return wallTime() }
        return reference.serverNow.addingTimeInterval(max(0, uptime() - uptimeAtReceipt))
    }
    /// se llama con cada respuesta que trae la hora del server
    /// no avisa a las pantallas, ellas se redibujan con los datos que llegaron en esa misma respuesta
    func synchronize(_ serverNow: Date) {
        reference = ServerTimeReference(serverNow: serverNow, receivedAt: wallTime())
        uptimeAtReceipt = uptime()
    }
    /// Una respuesta en vivo siempre gana sobre una copia. Sin red tras reiniciar,
    /// la estimación depende del reloj local: la UI sigue identificando los datos como copia.
    func restore(_ saved: ServerTimeReference) {
        guard reference == nil else { return }
        synchronize(saved.serverNow.addingTimeInterval(max(0, wallTime().timeIntervalSince(saved.receivedAt))))
    }
    func snapshot() -> ServerTimeReference {
        ServerTimeReference(serverNow: now, receivedAt: wallTime())
    }
}
