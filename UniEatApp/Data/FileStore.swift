import Foundation
import UniEatCore

/// Un ejecutor ordena el I/O de detalles y borradores fuera del hilo principal.
/// La limpieza invalida la generación saliente antes de borrar: una tarea tardía no recrea sus archivos.
actor FileStore {
    enum Folder: Sendable { case caches, support }
    private let cachesDirectory: URL
    private let supportDirectory: URL
    private nonisolated let sessionGate = FileSessionGate()
    private var latestRevisions: [String: UInt64] = [:]

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
    
    /// AppStore activa la generación antes de arrancar servicios. nil conserva lo pendiente al vencer la sesión.
    nonisolated func setSession(userID: UUID?, generation: UUID) {
        sessionGate.setSession(userID: userID, generation: generation)
    }

    /// Cierra la admisión sin esperar al actor: también corta tareas de generaciones vencidas anteriores.
    nonisolated func invalidate(userID: UUID) { sessionGate.invalidate(userID: userID) }

    private func allow(userId: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGate.allows(userID: userId, generation: generation) else { throw CancellationError() }
    }

    private func allowRevision(_ revision: UInt64?, name: String, folder: Folder, userId: UUID) throws {
        guard let revision else { return }
        let key = "\(userId):\(folder):\(name)"
        guard revision >= (latestRevisions[key] ?? 0) else { throw CancellationError() }
        latestRevisions[key] = revision
    }

    /// Escritura atómica y protegida; quien llama informa los fallos de disco.
    func save<Value: Encodable & Sendable>(_ value: Value, name: String, folder: Folder,
                                           userId: UUID, generation: UUID, revision: UInt64? = nil) throws {
        try allow(userId: userId, generation: generation)
        try allowRevision(revision, name: name, folder: folder, userId: userId)
        let data = try UniEatDates.encoder().encode(value)
        try FileManager.default.createDirectory(at: directory(folder, userId: userId), withIntermediateDirectories: true)
        try data.write(to: url(name, folder, userId), options: [.atomic, .completeFileProtection])
    }

    /// Leer no crea carpetas. Una copia ausente es nil; corrupción o error de disco se propagan.
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

    /// Comparte el orden de las escrituras. Lo ya escrito se elimina y lo tardío queda invalidado.
    func removeAll(userId: UUID, invalidating generation: UUID) throws {
        sessionGate.revoke(generation: generation)
        sessionGate.invalidate(userID: userId)
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

/// Solo protege identidad/admisión; el actor sigue siendo el único dueño del I/O.
/// El lock permite invalidar desde MainActor antes de suspenderse esperando la limpieza.
private final class FileSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var configured = false
    private var latest: [UUID: UUID] = [:]
    private var forgotten: Set<UUID> = []
    private var revoked: Set<UUID> = []

    func setSession(userID: UUID?, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        configured = true
        if let userID {
            latest[userID] = generation
            forgotten.remove(userID)
        }
    }

    func invalidate(userID: UUID) {
        lock.lock(); defer { lock.unlock() }
        latest.removeValue(forKey: userID)
        forgotten.insert(userID)
    }

    func revoke(generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        revoked.insert(generation)
    }

    func allows(userID: UUID, generation: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !revoked.contains(generation) else { return false }
        // Las pruebas de archivos aislados no necesitan construir AppStore ni una sesión completa.
        guard configured else { return true }
        return !forgotten.contains(userID) && latest[userID] == generation
    }
}
