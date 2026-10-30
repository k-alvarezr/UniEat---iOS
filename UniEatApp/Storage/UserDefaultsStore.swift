import Foundation
import UniEatCore

/// guardar y leer cosas pequeñas en UserDefaults como json (filtros, copia del feed, guardados)
/// es lo mismo que hacia el save y load del AppStore viejo, solo que aparte para que lo use cualquiera
enum UserDefaultsStore {
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
