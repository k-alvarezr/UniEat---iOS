import Foundation

/// puerta de escrituras por sesion, la usan FileStore (detalles y borrador) y LocalContentStore (feed)
/// guarda la generacion vigente de cada usuario: una escritura que trae otra generacion se rechaza
/// asi una tarea que termina despues de cerrar sesion no vuelve a crear lo que se acababa de borrar
/// usa un lock y no un actor porque cerrar sesion la tiene que cerrar de una, sin esperar a nadie
final class SessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var configured = false          // sin configurar (pruebas sueltas) se permite todo
    private var current: [UUID: UUID] = [:] // usuario -> generacion vigente
    private var revoked: Set<UUID> = []     // generaciones cerradas al cerrar sesion

    /// AppContainer la llama al entrar o salir alguien
    /// userID nil (la sesion vencio sola) no toca a nadie, asi lo pendiente del usuario se conserva
    func setSession(userID: UUID?, generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        configured = true
        if let userID { current[userID] = generation }
    }

    /// al cerrar sesion a mano: ese usuario ya no puede escribir hasta que vuelva a entrar
    func forget(userID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        current.removeValue(forKey: userID)
    }

    /// cierra una generacion para siempre, aunque el usuario vuelva a entrar con otra
    func revoke(_ generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        revoked.insert(generation)
    }

    /// true si ese usuario puede escribir con esa generacion
    /// generation nil es la vigente del usuario en este momento
    func allows(userID: UUID, generation: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // una generacion cerrada nunca vuelve a escribir, aunque la puerta no este configurada
        if let generation, revoked.contains(generation) { return false }
        guard configured else { return true }
        guard let expected = generation ?? current[userID] else { return false }
        return !revoked.contains(expected) && current[userID] == expected
    }

    /// permiso que se revisa ahora y otra vez justo antes de escribir dentro del actor
    /// la generacion se fija al pedir el permiso, si cambia en el camino la escritura se rechaza
    func permit(userID: UUID, generation: UUID?) -> WritePermit {
        lock.lock()
        let expected = generation ?? current[userID]
        let open = !configured
        lock.unlock()
        return WritePermit { [self] in
            if open { return allows(userID: userID, generation: nil) }
            guard let expected else { return false }
            return allows(userID: userID, generation: expected)
        }
    }
}

/// permiso para escribir, se revisa con check() justo antes de tocar el disco o la base
struct WritePermit: Sendable {
    let isValid: @Sendable () -> Bool
    func check() throws {
        guard isValid() else { throw CancellationError() }
    }
}
