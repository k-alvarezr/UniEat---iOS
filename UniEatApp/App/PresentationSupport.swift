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
    /// nil si no hay nada con esa llave o si no se puede leer
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
}

/// hora del server y hora del celular cuando llego, se guarda junto a las copias
/// asi al abrir sin red se puede estimar que hora es en el server
struct ServerTimeReference: Codable, Sendable {
    let serverNow: Date    // hora que dijo el server
    let receivedAt: Date   // hora del celular cuando llego la respuesta
}

/// reloj de la app basado en la hora del server y no en la del celular
/// si el usuario cambia la hora del celular la vigencia no se daña, porque se cuenta con el uptime
/// (segundos desde que prendio el celular, eso no se puede cambiar a mano)
@MainActor
final class ServerClock: ObservableObject {
    private var reference: ServerTimeReference?    // ultima hora del server, nil si todavia no llega
    private var uptimeAtReceipt: TimeInterval = 0  // uptime cuando llego esa hora
    private let uptime: () -> TimeInterval         // se inyecta para poder probarlo
    private let wallTime: () -> Date               // hora del celular, tambien inyectada
    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallTime: @escaping () -> Date = { .now }) {
        self.uptime = uptime
        self.wallTime = wallTime
    }
    /// hora actual: la del server mas lo que ha pasado desde que llego, si no hay server la del celular
    var now: Date {
        guard let reference else { return wallTime() }
        return reference.serverNow.addingTimeInterval(max(0, uptime() - uptimeAtReceipt))
    }
    /// se llama con cada respuesta que trae la hora del server
    func synchronize(_ serverNow: Date) {
        objectWillChange.send()
        reference = ServerTimeReference(serverNow: serverNow, receivedAt: wallTime())
        uptimeAtReceipt = uptime()
    }
    /// al abrir sin red se usa la hora guardada con la copia mas el tiempo que paso en el celular
    /// solo si en esta apertura no ha llegado una hora real del server
    func restore(_ saved: ServerTimeReference) {
        guard reference == nil else { return }
        synchronize(saved.serverNow.addingTimeInterval(max(0, wallTime().timeIntervalSince(saved.receivedAt))))
    }
    /// la hora actual lista para guardarla junto a una copia
    func snapshot() -> ServerTimeReference { ServerTimeReference(serverNow: now, receivedAt: wallTime()) }
}
