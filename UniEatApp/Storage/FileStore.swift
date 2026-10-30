import Foundation
import UniEatCore

/// guarda json en archivos del celular, separado por usuario (#33)
/// el detalle va en Caches porque se puede volver a bajar y el sistema lo puede borrar si falta espacio
/// el borrador va en Application Support porque es trabajo del usuario y no se debe perder
/// es un actor: el disco se toca fuera del hilo principal y las escrituras van en orden
/// al cerrar sesion se cierra la puerta antes de borrar, asi una tarea tardia no vuelve a crear los archivos
actor FileStore {
    enum Folder: Sendable { case caches, support }
    private let cachesDirectory: URL
    private let supportDirectory: URL
    private nonisolated let sessionGate = SessionGate()
    private var latestRevisions: [String: UInt64] = [:]   // ultima revision escrita de cada archivo (borrador)

    init(cachesDirectory: URL = .cachesDirectory, supportDirectory: URL = .applicationSupportDirectory) {
        self.cachesDirectory = cachesDirectory
        self.supportDirectory = supportDirectory
    }

    private func directory(_ folder: Folder, userId: UUID) -> URL {
        let base = folder == .caches ? cachesDirectory : supportDirectory
        return base.appending(path: "unieat/\(userId.uuidString)", directoryHint: .isDirectory)
    }
    
    private func url(_ name: String, _ folder: Folder, _ userId: UUID) -> URL {
        directory(folder, userId: userId).appending(path: name + ".json")
    }
    
    /// AppContainer abre la puerta con la sesion nueva antes de arrancar los servicios
    /// nil (la sesion vencio sola) conserva lo pendiente
    nonisolated func setSession(userID: UUID?, generation: UUID) {
        sessionGate.setSession(userID: userID, generation: generation)
    }

    /// cierra la puerta del usuario de una, sin esperar las escrituras que el actor tenga en cola
    nonisolated func invalidate(userID: UUID) { sessionGate.forget(userID: userID) }

    private func allow(userId: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGate.allows(userID: userId, generation: generation) else { throw CancellationError() }
    }

    // el borrador se guarda con un numero de revision, uno viejo que llega tarde no pisa uno nuevo
    private func allowRevision(_ revision: UInt64?, name: String, folder: Folder, userId: UUID) throws {
        guard let revision else { return }
        let key = "\(userId):\(folder):\(name)"
        guard revision >= (latestRevisions[key] ?? 0) else { throw CancellationError() }
        latestRevisions[key] = revision
    }

    /// escritura atomica (si la app se cierra a mitad no queda un archivo roto) y protegida con el celular bloqueado
    /// lanza el error para que la pantalla avise si no se pudo guardar
    func save<Value: Encodable & Sendable>(_ value: Value, name: String, folder: Folder,
                                           userId: UUID, generation: UUID, revision: UInt64? = nil) throws {
        try allow(userId: userId, generation: generation)
        try allowRevision(revision, name: name, folder: folder, userId: userId)
        let data = try UniEatDates.encoder().encode(value)
        try FileManager.default.createDirectory(at: directory(folder, userId: userId), withIntermediateDirectories: true)
        try data.write(to: url(name, folder, userId), options: [.atomic, .completeFileProtection])
    }

    /// nil si no hay copia, si el archivo esta dañado lanza el error
    func load<Value: Decodable & Sendable>(_ type: Value.Type, name: String, folder: Folder, userId: UUID) throws -> Value? {
        let path = url(name, folder, userId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try UniEatDates.decoder().decode(type, from: Data(contentsOf: path))
    }

    func remove(name: String, folder: Folder, userId: UUID, generation: UUID, revision: UInt64? = nil) throws {
        try allow(userId: userId, generation: generation)
        try allowRevision(revision, name: name, folder: folder, userId: userId)
        let path = url(name, folder, userId)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// cerrar sesion: cierra la puerta de esa sesion y borra las dos carpetas del usuario
    /// como es el mismo actor, lo que ya se estaba escribiendo termina antes de borrar
    func removeAll(userId: UUID, invalidating generation: UUID) throws {
        sessionGate.revoke(generation)
        sessionGate.forget(userID: userId)
        var failure: Error?
        for folder in [Folder.caches, .support] {
            let path = directory(folder, userId: userId)
            do {
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}
