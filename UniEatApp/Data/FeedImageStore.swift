import CryptoKit
import Foundation
import ImageIO
import Kingfisher
import UniformTypeIdentifiers
import UniEatCore

/// Public thumbnails: bounded child tasks, background decoding and atomic hashed files.
struct FeedImageStore: Sendable {
    static let lifetime: TimeInterval = 7 * 86_400
    static let diskLimit = 50 * 1024 * 1024
    let directory: URL
    private let fetch: @Sendable (URL) async throws -> Data
    init(directory: URL = URL.cachesDirectory.appending(path: "unieat-feed-images", directoryHint: .isDirectory),
         fetch: @escaping @Sendable (URL) async throws -> Data = FeedImageStore.download) {
        self.directory = directory; self.fetch = fetch
    }
    static func filename(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
    func localFile(_ url: URL) async -> URL? {
        await Task.detached(priority: .utility) { freshFile(url) }.value
    }
    private func freshFile(_ url: URL) -> URL? {
        let path = directory.appending(path: Self.filename(url))
        guard let values = try? path.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, Date.now.timeIntervalSince(date) < Self.lifetime,
              (values.fileSize ?? 0) > 0 else { return nil }
        return path
    }
    func prefetch(_ menus: [DailyMenu]) async -> Int {
        let urls = Set(menus.compactMap { $0.photoUrl.flatMap(URL.init(string:)) }.filter { $0.scheme == "https" })
        var waiting = urls.makeIterator()
        let stored = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<4 { if let url = waiting.next() { group.addTask(priority: .utility) { await store(url) } } }
            var count = 0
            for await success in group {
                if success { count += 1 }
                if Task.isCancelled { group.cancelAll(); break }
                if let url = waiting.next() { group.addTask(priority: .utility) { await store(url) } }
            }
            return count
        }
        await clean()
        return stored
    }
    private func store(_ url: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        if await localFile(url) != nil { return true }
        do {
            let original = try await fetch(url)
            guard original.count <= 10 * 1024 * 1024 else { return false }
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
            let thumbnail = try await withTaskCancellationHandler(operation: { try await processing.value }, onCancel: { processing.cancel() })
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try thumbnail.write(to: directory.appending(path: Self.filename(url)), options: [.atomic, .completeFileProtection])
            return true
        } catch { return false }
    }
    func clean() async {
        await Task.detached(priority: .background) {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
            var files: [(URL, Date, Int)] = []
            for url in urls where url.pathExtension == "jpg" {
                guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true else { continue }
                let date = value.contentModificationDate ?? .distantPast
                if Date.now.timeIntervalSince(date) >= Self.lifetime { try? FileManager.default.removeItem(at: url) }
                else { files.append((url, date, value.fileSize ?? 0)) }
            }
            var size = files.reduce(0) { $0 + $1.2 }
            for file in files.sorted(by: { $0.1 < $1.1 }) where size > Self.diskLimit {
                do { try FileManager.default.removeItem(at: file.0); size -= file.2 } catch { }
            }
        }.value
    }
    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true else { throw URLError(.badServerResponse) }
        return data
    }
}

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
