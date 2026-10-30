import Foundation
import UniEatCore

/// guarda json en archivos del celular, separado por usuario
/// el detalle va en Caches porque se puede volver a bajar y el sistema lo puede borrar si falta espacio
/// el borrador va en Application Support porque es trabajo del usuario y no se debe perder
struct FileStore: Sendable {
    enum Folder {case caches, support}
    //carpeta del usuario, se crea la primera vez
    private func directory(_ folder: Folder, userId: UUID) -> URL {
        let base = folder == .caches ? URL.cachesDirectory : URL.applicationSupportDirectory
        let dir = base.appending(path: "unieat/\(userId.uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func url(_ name: String, _ folder: Folder, _ userId: UUID) -> URL {
        directory(folder, userId: userId).appending(path: name + ".json")
    }
    
    func save<Value: Encodable>(_ value: Value, name: String, folder: Folder, userId: UUID){
        guard let data = try? UniEatDates.encoder().encode(value) else { return }
        // atomic (crea un temporal y luego el temporal lo guarda) para que si la app se cierra a mitad no quede un archivo roto
        // y protegido para que no se lea con el celular bloqueado
        try? data.write(to: url(name, folder, userId), options: [.atomic, .completeFileProtection])
    }
    
    func load<Value: Decodable>(_ type: Value.Type, name: String, folder: Folder, userId: UUID) -> Value? {
        guard let data = try? Data(contentsOf: url(name, folder, userId)) else { return nil }
        return try? UniEatDates.decoder().decode(type, from: data)
    }
    
    func remove(name: String, folder: Folder, userId: UUID) {
        try? FileManager.default.removeItem(at: url(name, folder, userId))
    }
    
    /// borra las dos carpetas del usuario, se usa al cerrar sesion
    func removeAll(userId: UUID) {
        try? FileManager.default.removeItem(at: directory(.caches, userId: userId))
        try? FileManager.default.removeItem(at: directory(.support, userId: userId))
    }
}
