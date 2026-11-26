import XCTest
@testable import UniEat

@MainActor
final class PublicationTimingStorageTests: XCTestCase {
    func testCopyIsScopedToAccountAndOlderResponsesCannotReplaceIt() async throws {
        let database = try LocalDatabase(inMemory: true)
        let content = LocalContentService(container: database.container)
        let owner = UUID(), generation = UUID(), other = UUID()
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let current = PublicationTimingSnapshot(periodDays: 28, asOf: time, minimumSessions: 5, groups: [])
        let older = PublicationTimingSnapshot(periodDays: 28, asOf: time.addingTimeInterval(-1), minimumSessions: 5, groups: [])

        content.setSession(userID: owner, generation: generation)
        try await content.savePublicationTiming(current, userID: owner, generation: generation)
        try await content.savePublicationTiming(older, userID: owner, generation: generation)
        let ownerCopy = try await content.publicationTiming(userID: owner)
        let otherCopy = try await content.publicationTiming(userID: other)
        XCTAssertEqual(ownerCopy?.asOf, time)
        XCTAssertNil(otherCopy)

        try await content.forget(userID: owner, generation: generation)
        do {
            try await content.savePublicationTiming(current, userID: owner, generation: generation)
            XCTFail("A response from the closed session restored the copy")
        } catch is CancellationError {}
        let deletedCopy = try await content.publicationTiming(userID: owner)
        XCTAssertNil(deletedCopy)
    }
}
