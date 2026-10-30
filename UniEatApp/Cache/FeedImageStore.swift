import Foundation
import CryptoKit
import Kingfisher
import UniEatCore

/// una sola copia procesada por URL, la precarga y las tarjetas usan el mismo Kingfisher
/// el grupo tiene maximo cuatro tareas de disco y red, el coordinador tambien limita las descargas
/// entre grupos y vistas, si dos piden la misma URL se baja una vez y se respeta la cancelacion
struct FeedImageStore: Sendable {
    typealias Retrieval = @Sendable (URL) async throws -> Void
    static let lifetime: TimeInterval = 7 * 86_400
    static let diskLimit: UInt = 50 * 1024 * 1024
    let cache: ImageCache
    private let legacyDirectory: URL?
    private let legacyCache: ImageCache?
    private let requests: FeedImageRequests

    init(cache: ImageCache = KingfisherSetup.cache,
         legacyDirectory: URL? = URL.cachesDirectory.appending(path: "unieat-feed-images", directoryHint: .isDirectory),
         legacyCache: ImageCache? = .default,
         retrieve: Retrieval? = nil) {
        self.cache = cache
        self.legacyDirectory = legacyDirectory
        self.legacyCache = legacyCache
        let manager = KingfisherManager(downloader: .default, cache: cache)
        requests = FeedImageRequests { url, allowNetwork in
            if let retrieve {
                try await retrieve(url)
                return
            }
            let cached = await cache.imageCachedTypeAsync(forKey: url.absoluteString,
                processorIdentifier: KingfisherSetup.processor.identifier)
            if cached.cached { return }
            try Task.checkCancellation()
            // mismo procesador y llave que KFImage, no se guarda tambien la original
            let old = await Self.legacyFile(url, directory: legacyDirectory, cache: legacyCache)
            let source: Source = old.map { .provider(LocalFileImageDataProvider(fileURL: $0, cacheKey: url.absoluteString)) }
                ?? .network(KF.ImageResource(downloadURL: url))
            var options: KingfisherOptionsInfo = [
                .targetCache(cache), .processor(KingfisherSetup.processor),
                .waitForCache, .backgroundDecode, .diskCacheAccessExtendingExpiration(.none)
            ]
            if !allowNetwork && old == nil { options.append(.onlyFromCache) }
            _ = try await manager.retrieveImage(with: source, options: options)
            // sin red se conservan las fotos anteriores, el archivo viejo solo se borra
            // despues de pasarlo al cache unico, cuando ya no hace falta
            if let old {
                _ = await Task.detached(priority: .utility) {
                    // que la imagen este en memoria no quiere decir que se guardo en disco
                    // si fallo el guardado la copia vieja sigue sirviendo al abrir sin red
                    guard cache.cacheFileURLIfOnDisk(forKey: url.absoluteString,
                        processorIdentifier: KingfisherSetup.processor.identifier) != nil else { return }
                    try? FileManager.default.removeItem(at: old)
                }.value
            }
        }
    }

    /// las tarjetas en pantalla van primero, sin red solo se busca lo que ya se bajo
    func load(_ url: URL, allowNetwork: Bool) async -> Bool {
        guard url.scheme == "https", !Task.isCancelled else { return false }
        if await isCached(url) { return true }
        if !allowNetwork, await Self.legacyFile(url, directory: legacyDirectory, cache: legacyCache) == nil { return false }
        return await requests.load(url, visible: true, allowNetwork: allowNetwork)
    }

    /// Kingfisher nombra el archivo con SHA-256 de la URL + procesador, todo en una carpeta
    func localFile(_ url: URL) async -> URL? {
        let cache = cache
        return await Task.detached(priority: .utility) { () -> URL? in
            cache.cacheFileURLIfOnDisk(forKey: url.absoluteString,
                processorIdentifier: KingfisherSetup.processor.identifier)
        }.value
    }

    private func isCached(_ url: URL) async -> Bool {
        let type = await cache.imageCachedTypeAsync(forKey: url.absoluteString,
            processorIdentifier: KingfisherSetup.processor.identifier)
        return type.cached
    }

    private static func legacyFile(_ url: URL, directory: URL?, cache: ImageCache?) async -> URL? {
        return await Task.detached(priority: .utility) { () -> URL? in
            if let directory {
                let filename = SHA256.hash(data: Data(url.absoluteString.utf8))
                    .map { String(format: "%02x", $0) }.joined() + ".jpg"
                let file = directory.appending(path: filename)
                if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let date = values.contentModificationDate,
                   max(0, Date.now.timeIntervalSince(date)) < Self.lifetime,
                   (values.fileSize ?? 0) > 0 { return file }
            }
            // algunas fotos solo estaban en el Kingfisher viejo, esas tambien se pasan sin red
            return cache?.cacheFileURLIfOnDisk(forKey: url.absoluteString,
                processorIdentifier: KingfisherSetup.processor.identifier)
                ?? cache?.cacheFileURLIfOnDisk(forKey: url.absoluteString)
        }.value
    }

    /// respeta el orden del feed con maximo cuatro tareas a la vez, no precarga todo el catalogo
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
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let url = waiting.next() {
                    group.addTask(priority: .utility) { await requests.load(url, visible: false) }
                }
            }
            return stored
        }
    }

    /// la libreria limpia su disco una vez al arrancar, no despues de cada lote
    /// en la migracion solo se borran los JPEG viejos vencidos, los vigentes sirven sin red
    func clean() async {
        await cache.cleanExpiredDiskCache()
        await legacyCache?.cleanExpiredDiskCache()
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

/// cada quien espera por su lado, cancelar la precarga no cancela una foto que sigue en pantalla
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
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
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
                do {
                    try await retrieve(url, request.allowNetwork)
                    success = !Task.isCancelled
                } catch {
                    success = false
                }
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
            // el cupo se libera cuando la tarea cancelada de verdad termino
            task.cancel()
        } else {
            requests.removeValue(forKey: id)
            waiting.removeAll { $0 == id }
        }
    }
}

/// un solo cache y un solo formato procesado para tareas y vistas
enum KingfisherSetup {
    static let cache = ImageCache(name: "unieat-feed-images")
    static let processor = DownsamplingImageProcessor(size: CGSize(width: 720, height: 480))
    static func configure() {
        cache.memoryStorage.config.totalCostLimit = 50 * 1024 * 1024
        cache.memoryStorage.config.countLimit = 100
        cache.diskStorage.config.sizeLimit = FeedImageStore.diskLimit
        cache.diskStorage.config.expiration = .seconds(FeedImageStore.lifetime)
    }
}
