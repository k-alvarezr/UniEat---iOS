import Foundation
import CryptoKit
import Kingfisher
import UniEatCore

/// Una sola copia procesada por URL: la precarga y las tarjetas comparten Kingfisher.
/// El grupo mantiene cuatro hijos de I/O; el coordinador limita también las descargas
/// entre grupos y vistas, comparte pedidos por URL y respeta su cancelación.
struct FeedImageStore: Sendable {
    typealias Retrieval = @Sendable (URL) async throws -> Void
    static let lifetime: TimeInterval = 7 * 86_400
    static let diskLimit: UInt = 50 * 1024 * 1024
    let cache: ImageCache
    private let legacyDirectory: URL?
    private let requests: FeedImageRequests

    init(cache: ImageCache = ImageLibraryConfiguration.cache,
         legacyDirectory: URL? = URL.cachesDirectory.appending(path: "unieat-feed-images", directoryHint: .isDirectory),
         retrieve: Retrieval? = nil) {
        self.cache = cache
        self.legacyDirectory = legacyDirectory
        let manager = KingfisherManager(downloader: .default, cache: cache)
        requests = FeedImageRequests { url, allowNetwork in
            if let retrieve { try await retrieve(url); return }
            // El mismo procesador y llave que KFImage. No se guarda además el original.
            let old = await Self.legacyFile(url, directory: legacyDirectory)
            let source: Source = old.map { .provider(LocalFileImageDataProvider(fileURL: $0, cacheKey: url.absoluteString)) }
                ?? .network(ImageResource(downloadURL: url))
            var options: KingfisherOptionsInfo = [
                .targetCache(cache), .processor(ImageLibraryConfiguration.processor),
                .waitForCache, .backgroundDecode, .diskCacheAccessExtendingExpiration(.none)
            ]
            if !allowNetwork && old == nil { options.append(.onlyFromCache) }
            _ = try await manager.retrieveImage(with: source, options: options)
            // Una actualización sin red conserva las fotos anteriores. Solo después de importarlas
            // al caché único se retira su archivo viejo, que ya dejó de ser la fuente de la imagen.
            if let old {
                _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: old) }.value
            }
        }
    }

    /// Las tarjetas visibles piden prioridad; sin red solo se busca lo ya descargado.
    func load(_ url: URL, allowNetwork: Bool) async -> Bool {
        guard url.scheme == "https", !Task.isCancelled else { return false }
        if await isCached(url) { return true }
        if !allowNetwork, await Self.legacyFile(url, directory: legacyDirectory) == nil { return false }
        return await requests.load(url, visible: true, allowNetwork: allowNetwork)
    }

    /// Kingfisher administra el archivo por SHA-256 de URL + procesador en un solo directorio.
    func localFile(_ url: URL) async -> URL? {
        let cache = cache
        return await Task.detached(priority: .utility) { () -> URL? in
            cache.cacheFileURLIfOnDisk(forKey: url.absoluteString,
                processorIdentifier: ImageLibraryConfiguration.processor.identifier)
        }.value
    }

    private func isCached(_ url: URL) async -> Bool {
        let type = await cache.imageCachedTypeAsync(forKey: url.absoluteString,
            processorIdentifier: ImageLibraryConfiguration.processor.identifier)
        return type.cached
    }

    private static func legacyFile(_ url: URL, directory: URL?) async -> URL? {
        guard let directory else { return nil }
        return await Task.detached(priority: .utility) { () -> URL? in
            let filename = SHA256.hash(data: Data(url.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined() + ".jpg"
            let file = directory.appending(path: filename)
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate,
                  Date.now.timeIntervalSince(date) >= 0, Date.now.timeIntervalSince(date) < Self.lifetime,
                  (values.fileSize ?? 0) > 0 else { return nil }
            return file
        }.value
    }

    /// Conserva el orden del feed y un grupo de hasta cuatro hijos; no precarga todo el catálogo.
    func prefetch(_ menus: [DailyMenu]) async -> Int {
        var seen = Set<URL>()
        let urls = menus.compactMap { $0.photoUrl.flatMap(URL.init(string:)) }
            .filter { $0.scheme == "https" && seen.insert($0).inserted }
        var waiting = urls.makeIterator()
        return await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<4 {
                guard let url = waiting.next() else { break }
                group.addTask(priority: .utility) { await requests.load(url, visible: false) }
            }
            var stored = 0
            for await success in group {
                if success { stored += 1 }
                if Task.isCancelled { group.cancelAll(); break }
                if let url = waiting.next() {
                    group.addTask(priority: .utility) { await requests.load(url, visible: false) }
                }
            }
            return stored
        }
    }

    /// La librería limpia su disco una vez al arrancar, no después de cada lote.
    /// Durante la migración solo se retiran JPEG viejos vencidos: los vigentes aún sirven offline.
    func clean() async {
        await cache.cleanExpiredDiskCache()
        guard let legacyDirectory else { return }
        await Task.detached(priority: .background) {
            let files = (try? FileManager.default.contentsOfDirectory(at: legacyDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
            for file in files where file.pathExtension == "jpg" {
                guard let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      info.isRegularFile == true, let date = info.contentModificationDate,
                      Date.now.timeIntervalSince(date) >= Self.lifetime else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }.value
    }
}

/// Cada consumidor tiene su espera: cancelar la precarga no cancela una foto todavía visible.
private actor FeedImageRequests {
    private struct Request {
        let url: URL
        var allowNetwork: Bool
        var waiters: [UUID: CheckedContinuation<Bool, Never>]
        var task: Task<Void, Never>?
    }
    private let retrieve: @Sendable (URL, Bool) async throws -> Void
    private var requests: [UUID: Request] = [:]
    private var current: [URL: UUID] = [:]
    private var waiting: [UUID] = []
    private var active = 0

    init(retrieve: @escaping @Sendable (URL, Bool) async throws -> Void) { self.retrieve = retrieve }

    func load(_ url: URL, visible: Bool, allowNetwork: Bool = true) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let id: UUID
                if let existing = current[url] {
                    id = existing
                    requests[id]?.waiters[waiterID] = continuation
                    if allowNetwork { requests[id]?.allowNetwork = true }
                    if visible, requests[id]?.task == nil {
                        waiting.removeAll { $0 == id }
                        waiting.insert(id, at: 0)
                    }
                } else {
                    id = UUID()
                    requests[id] = Request(url: url, allowNetwork: allowNetwork, waiters: [waiterID: continuation])
                    current[url] = id
                    if visible { waiting.insert(id, at: 0) } else { waiting.append(id) }
                }
                startWaiting()
            }
        } onCancel: {
            Task { await self.cancel(url: url, waiterID: waiterID) }
        }
    }

    private func startWaiting() {
        while active < 4, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let request = requests[id] else { continue }
            active += 1
            let retrieve = retrieve, url = request.url
            requests[id]?.task = Task(priority: .utility) {
                let success: Bool
                do { try await retrieve(url, request.allowNetwork); success = !Task.isCancelled }
                catch { success = false }
                self.complete(id: id, success: success)
            }
        }
    }

    private func complete(id: UUID, success: Bool) {
        guard let request = requests.removeValue(forKey: id) else { return }
        if current[request.url] == id { current.removeValue(forKey: request.url) }
        active -= 1
        for waiter in request.waiters.values { waiter.resume(returning: success) }
        startWaiting()
    }

    private func cancel(url: URL, waiterID: UUID) {
        guard let id = current[url], let waiter = requests[id]?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: false)
        guard requests[id]?.waiters.isEmpty == true else { return }
        current.removeValue(forKey: url)
        if let task = requests[id]?.task {
            // El cupo no se libera hasta que el trabajo cancelado haya terminado de verdad.
            task.cancel()
        } else {
            requests.removeValue(forKey: id)
            waiting.removeAll { $0 == id }
        }
    }
}

/// Un único caché y un único formato procesado, compartidos por tareas y vistas.
enum ImageLibraryConfiguration {
    static let cache = ImageCache(name: "unieat-feed-images")
    static let processor = DownsamplingImageProcessor(size: CGSize(width: 720, height: 480))
    static func configure() {
        cache.memoryStorage.config.totalCostLimit = 50 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 100
        cache.diskStorage.config.sizeLimit = FeedImageStore.diskLimit
        cache.diskStorage.config.expiration = .seconds(FeedImageStore.lifetime)
    }
}
