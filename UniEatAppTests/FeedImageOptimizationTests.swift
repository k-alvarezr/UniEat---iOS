import CryptoKit
import ImageIO
import Kingfisher
import UIKit
import XCTest
import UniEatCore
@testable import UniEat

@MainActor
final class FeedImageOptimizationTests: XCTestCase {
    func testOverlappingGroupsShareURLsAndNeverExceedFourRetrievals() async throws {
        let cache = ImageCache(name: UUID().uuidString), probe = ImageWorkProbe()
        let images = FeedImageStore(cache: cache, legacyDirectory: nil) { url in
            // El doble simula el caché del manager: una recuperación ya terminada no vuelve a bajar.
            guard await probe.begin(url) else { return }
            try await Task.sleep(for: .milliseconds(60))
            await probe.end(url)
        }
        let menus = (0..<8).map { i in
            DailyMenu(title: "Foto", validUntil: .now.addingTimeInterval(3600), establishmentName: "Test",
                area: "Centro", address: "Test", photoUrl: "https://example.invalid/image-\(i)", items: [], lowestPriceCop: 1)
        }
        async let first = images.prefetch(menus)
        async let second = images.prefetch(menus)
        let counts = await (first, second)
        XCTAssertEqual(counts.0, 8)
        XCTAssertEqual(counts.1, 8)
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 4)
        let perURL = await probe.started
        XCTAssertEqual(perURL.count, 8)
        XCTAssertTrue(perURL.values.allSatisfy { $0 == 1 })
    }

    func testOfflineMissNeverInvokesTheDownloader() async {
        let cache = ImageCache(name: UUID().uuidString), probe = ImageWorkProbe()
        let images = FeedImageStore(cache: cache, legacyDirectory: nil) { url in _ = await probe.begin(url) }
        let ready = await images.load(URL(string: "https://example.invalid/offline")!, allowNetwork: false)
        XCTAssertFalse(ready)
        let starts = await probe.started
        XCTAssertTrue(starts.isEmpty)
    }

    func testLegacyThumbnailImportsIntoTheSharedCacheWithoutNetworkAndThenReusesIt() async throws {
        let cache = ImageCache(name: UUID().uuidString)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.invalid/legacy-photo")!
        let filename = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".jpg"
        let legacyFile = directory.appending(path: filename)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }.jpegData(compressionQuality: 0.8)!
        try data.write(to: legacyFile)
        // Un ajuste hacia atrás del reloj no hace desaparecer una foto ya descargada.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: legacyFile.path)
        let images = FeedImageStore(cache: cache, legacyDirectory: directory)
        let first = await images.load(url, allowNetwork: false)
        XCTAssertTrue(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let cachedFile = await images.localFile(url)
        let file = try XCTUnwrap(cachedFile)
        XCTAssertEqual(file.path, cache.cachePath(forKey: url.absoluteString,
            processorIdentifier: KingfisherSetup.processor.identifier))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 720)
        cache.clearMemoryCache()
        let second = await images.load(url, allowNetwork: false)
        XCTAssertTrue(second)
        await cache.clearDiskCache()
    }

    func testUpgradeKeepsPhotosThatOnlyExistedInTheOldKingfisherCache() async throws {
        let oldCache = ImageCache(name: UUID().uuidString), newCache = ImageCache(name: UUID().uuidString)
        let url = URL(string: "https://example.invalid/old-kingfisher-\(UUID())")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        try await oldCache.store(image, forKey: url.absoluteString,
            processorIdentifier: KingfisherSetup.processor.identifier)
        oldCache.clearMemoryCache()
        let images = FeedImageStore(cache: newCache, legacyDirectory: nil, legacyCache: oldCache)
        let ready = await images.load(url, allowNetwork: false)
        XCTAssertTrue(ready)
        let copiedFile = await images.localFile(url)
        XCTAssertNotNil(copiedFile)
        XCTAssertNil(oldCache.cacheFileURLIfOnDisk(forKey: url.absoluteString,
            processorIdentifier: KingfisherSetup.processor.identifier))
        await oldCache.clearDiskCache(); await newCache.clearDiskCache()
    }
}

private actor ImageWorkProbe {
    private var active = 0
    private var completed: Set<URL> = []
    private(set) var peak = 0
    private(set) var started: [URL: Int] = [:]
    func begin(_ url: URL) -> Bool {
        guard !completed.contains(url) else { return false }
        active += 1; peak = max(peak, active); started[url, default: 0] += 1
        return true
    }
    func end(_ url: URL) { active -= 1; completed.insert(url) }
}
