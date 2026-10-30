import CryptoKit
import Foundation
import ImageIO
import Kingfisher
import UniformTypeIdentifiers
import UniEatCore

/// fotos del feed guardadas en disco para verlas sin red (#32, #34, #38)
/// se bajan con tareas hijas en paralelo (maximo 4), se achican en segundo plano y se guardan con nombre por hash de la url
struct FeedImageStore: Sendable {
    static let lifetime: TimeInterval = 7 * 86_400   // una foto dura 7 dias en disco
    static let diskLimit = 50 * 1024 * 1024          // maximo 50 MB, si se pasa se borran las mas viejas
    let directory: URL
    private let fetch: @Sendable (URL) async throws -> Data   // se inyecta para probar sin red
    init(directory: URL = URL.cachesDirectory.appending(path: "unieat-feed-images", directoryHint: .isDirectory),
         fetch: @escaping @Sendable (URL) async throws -> Data = FeedImageStore.download) {
        self.directory = directory
        self.fetch = fetch
    }
    /// nombre del archivo: hash sha256 de la url, asi la misma foto siempre cae en el mismo archivo
    static func filename(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
    /// el archivo de la foto si existe y no ha vencido, leer el disco va en segundo plano
    func localFile(_ url: URL) async -> URL? {
        await Task.detached(priority: .utility) { freshFile(url) }.value
    }
    // revisa que el archivo exista, no este vacio y tenga menos de 7 dias
    private func freshFile(_ url: URL) -> URL? {
        let path = directory.appending(path: Self.filename(url))
        guard let values = try? path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, Date.now.timeIntervalSince(date) < Self.lifetime,
              (values.fileSize ?? 0) > 0 else { return nil }
        return path
    }
    /// baja las fotos https de estos menus, maximo 4 a la vez con un TaskGroup
    /// cuando termina una entra la siguiente, al final limpia el disco, devuelve cuantas quedaron guardadas
    func prefetch(_ menus: [DailyMenu]) async -> Int {
        let urls = Set(menus.compactMap { $0.photoUrl.flatMap(URL.init(string:)) }.filter { $0.scheme == "https" })
        var waiting = urls.makeIterator()
        let stored = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<4 {
                guard let url = waiting.next() else { break }
                group.addTask(priority: .utility) { await store(url) }
            }
            var count = 0
            for await success in group {
                if success { count += 1 }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let url = waiting.next() {
                    group.addTask(priority: .utility) { await store(url) }
                }
            }
            return count
        }
        await clean()
        return stored
    }
    // baja una foto, la achica a 720 px en jpeg y la guarda, si ya estaba guardada no la baja otra vez
    private func store(_ url: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        if await localFile(url) != nil { return true }
        do {
            let original = try await fetch(url)
            guard original.count <= 10 * 1024 * 1024 else { return false }   // fotos de mas de 10 MB no
            // achicar la imagen es trabajo pesado, va en una tarea aparte fuera del hilo principal
            let processing = Task.detached(priority: .utility) { () throws -> Data in
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
                let buffer = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw URLError(.cannotDecodeContentData)
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                return buffer as Data
            }
            // si cancelan la descarga tambien se cancela el procesamiento
            let thumbnail = try await withTaskCancellationHandler(operation: { try await processing.value }, onCancel: { processing.cancel() })
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try thumbnail.write(to: directory.appending(path: Self.filename(url)), options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }
    /// borra fotos de mas de 7 dias y, si el disco pasa de 50 MB, las mas viejas, con prioridad background
    func clean() async {
        await Task.detached(priority: .background) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
            var files: [(URL, Date, Int)] = []
            for url in urls where url.pathExtension == "jpg" {
                guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true else { continue }
                let date = value.contentModificationDate ?? .distantPast
                if Date.now.timeIntervalSince(date) >= Self.lifetime {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    files.append((url, date, value.fileSize ?? 0))
                }
            }
            var size = files.reduce(0) { $0 + $1.2 }
            for file in files.sorted(by: { $0.1 < $1.1 }) where size > Self.diskLimit {
                do {
                    try FileManager.default.removeItem(at: file.0)
                    size -= file.2
                } catch {
                }
            }
        }.value
    }
    // baja la foto, acepta la cache http de URLSession porque son fotos publicas
    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        return data
    }
}

/// limites de Kingfisher, la libreria de imagenes de las tarjetas (#38)
/// memoria: 50 MB o 100 fotos, disco: 100 MB y vencen a los 7 dias
@MainActor
enum ImageLibraryConfiguration {
    static func configure() {
        let cache = ImageCache.default
        cache.memoryStorage.config.totalCostLimit = 50 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 100
        cache.diskStorage.config.sizeLimit = 100 * 1024 * 1024
        cache.diskStorage.config.expiration = .days(7)
    }
}
